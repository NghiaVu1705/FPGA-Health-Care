"""Hits the `shared_ai.cnn_timeout` coverage bin.

Uses parameter override `CNN_INFER_TIMEOUT=20` so the scheduler's ST_WAIT
watchdog fires within simulation time. The test feeds enough samples to
reach ST_WAIT (CNN will not naturally produce class_valid in 20 cycles for a
fresh frame), then verifies that `cnn_timeout_error` rises and the FSM
recovers by advancing `active_channel`.
"""
from pathlib import Path
import math

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

from coverage.functional_coverage import cover


PROJECT_ROOT = Path(__file__).resolve().parents[3]
HAMMING_HEX = PROJECT_ROOT / "rtl/gowin_bsram/hamming_coeff_rom.hex"
TWIDDLE_HEX = PROJECT_ROOT / "rtl/gowin_bsram/fft_twiddle_rom.hex"
EEG_WEIGHTS_HEX = PROJECT_ROOT / "rtl/gowin_bsram/eeg/cnn_weights.hex"


def _read_hex(path, pad_to=None):
    values = [int(line.strip(), 16) for line in path.read_text().splitlines() if line.strip()]
    if pad_to is not None and len(values) < pad_to:
        values += [0] * (pad_to - len(values))
    return values


def _pack_256(payload):
    value = 0
    for idx, byte in enumerate(payload):
        value |= (byte & 0xFF) << (idx * 8)
    return value


async def _reset(dut):
    dut.rst_n.value = 0
    dut.eeg_sample.value = 0
    dut.eeg_valid.value = 0
    dut.ecg_sample.value = 0
    dut.ecg_valid.value = 0
    dut.emg_sample.value = 0
    dut.emg_valid.value = 0
    dut.spo2_raw.value = 98
    dut.temp_raw.value = 37
    dut.vitals_updated.value = 0
    dut.hamming_rom_data.value = 0
    dut.twiddle_rom_data.value = 0
    dut.ddr_cmd_ready.value = 1
    dut.ddr_rd_data.value = 0
    dut.ddr_rd_data_valid.value = 0
    dut.ddr_rd_data_end.value = 0
    for _ in range(8):
        await RisingEdge(dut.sys_clk)
    dut.rst_n.value = 1
    for _ in range(4):
        await RisingEdge(dut.sys_clk)


async def _drive_roms(dut, hamming, twiddle):
    while True:
        await RisingEdge(dut.sys_clk)
        h_addr = dut.hamming_rom_addr.value
        t_addr = dut.twiddle_rom_addr.value
        dut.hamming_rom_data.value = hamming[int(h_addr) & 0x3F] if h_addr.is_resolvable else 0
        dut.twiddle_rom_data.value = twiddle[int(t_addr) & 0x1F] if t_addr.is_resolvable else 0


async def _drive_ddr_reads(dut, memories):
    pending = []
    while True:
        await RisingEdge(dut.sys_clk)
        if dut.ddr_cmd_en.value.is_resolvable and int(dut.ddr_cmd_en.value):
            addr = int(dut.ddr_addr.value)
            base = max((candidate for candidate in memories if candidate <= addr), default=0)
            offset = addr - base
            payload = memories.get(base, [0] * 512)[offset : offset + 32]
            payload += [0] * (32 - len(payload))
            pending.append(payload)
        if pending:
            dut.ddr_rd_data.value = _pack_256(pending.pop(0))
            dut.ddr_rd_data_valid.value = 1
            dut.ddr_rd_data_end.value = 1
        else:
            dut.ddr_rd_data_valid.value = 0
            dut.ddr_rd_data_end.value = 0


@cocotb.test()
async def test_cnn_timeout_fires_and_recovers(dut):
    """ST_WAIT watchdog: CNN never asserts class_valid within CNN_INFER_TIMEOUT cycles.

    Built with CNN_INFER_TIMEOUT=20 via parameter override (see filelist).
    Verifies:
      1. cnn_timeout_error rises within reasonable time after samples are fed.
      2. active_channel advances after the timeout (scheduler does not deadlock).
    """
    hamming = _read_hex(HAMMING_HEX)
    twiddle = _read_hex(TWIDDLE_HEX)
    memories = {
        0:    _read_hex(EEG_WEIGHTS_HEX, 512),
        4096: _read_hex(EEG_WEIGHTS_HEX, 512),
        8192: _read_hex(EEG_WEIGHTS_HEX, 512),
    }

    cocotb.start_soon(Clock(dut.sys_clk, 10, unit="ns").start())
    cocotb.start_soon(_drive_roms(dut, hamming, twiddle))
    cocotb.start_soon(_drive_ddr_reads(dut, memories))
    await _reset(dut)

    # Wait for the initial EEG prefetch to complete.
    for _ in range(2000):
        await RisingEdge(dut.sys_clk)
        if int(dut.weights_ready.value) == 1 and int(dut.active_channel.value) == 0:
            break
    else:
        raise AssertionError("EEG prefetch did not complete")

    initial_channel = int(dut.active_channel.value)

    # Feed exactly 2048 fixed samples to advance the FSM from ST_COLLECT
    # to ST_WAIT. CNN won't have time to emit class_valid within 20 cycles.
    samples_sent = 0
    while samples_sent < 2048:
        await RisingEdge(dut.sys_clk)
        if int(dut.eeg_ready.value):
            dut.eeg_sample.value = int(round(1000.0 * math.sin(2.0 * math.pi * samples_sent / 64.0))) & 0xFFFF
            dut.eeg_valid.value = 1
            samples_sent += 1
        else:
            dut.eeg_valid.value = 0
    # One extra edge so the last queued sample is consumed by the DUT
    # (mirrors the pattern in test_shared_ai_system.py).
    await RisingEdge(dut.sys_clk)
    dut.eeg_valid.value = 0

    # ST_WAIT entered; CNN_INFER_TIMEOUT=20 cycles should trip the watchdog
    # within ~25 cycles (20 timeout + a few overhead).
    saw_timeout_error = False
    saw_channel_advance = False
    for _ in range(5000):
        await RisingEdge(dut.sys_clk)
        if int(dut.cnn_timeout_error.value):
            saw_timeout_error = True
        if int(dut.active_channel.value) != initial_channel:
            saw_channel_advance = True
        if saw_timeout_error and saw_channel_advance:
            break

    assert saw_timeout_error, "cnn_timeout_error did not rise within 5000 cycles"
    assert saw_channel_advance, "Scheduler did not advance channel after timeout"
    cover("shared_ai.cnn_timeout")
