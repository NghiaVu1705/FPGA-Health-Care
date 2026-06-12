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
ECG_WEIGHTS_HEX = PROJECT_ROOT / "rtl/gowin_bsram/ecg/cnn_weights.hex"
EMG_WEIGHTS_HEX = PROJECT_ROOT / "rtl/gowin_bsram/emg/cnn_weights.hex"


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


async def _wait_for(dut, predicate, limit, message):
    for _ in range(limit):
        await RisingEdge(dut.sys_clk)
        if predicate():
            return
    raise AssertionError(message)


@cocotb.test()
async def test_shared_ai_prefetches_weights_and_runs_one_eeg_slot(dut):
    hamming = _read_hex(HAMMING_HEX)
    twiddle = _read_hex(TWIDDLE_HEX)
    memories = {
        0: _read_hex(EEG_WEIGHTS_HEX, 512),
        4096: _read_hex(ECG_WEIGHTS_HEX, 512),
        8192: _read_hex(EMG_WEIGHTS_HEX, 512),
    }

    cocotb.start_soon(Clock(dut.sys_clk, 10, unit="ns").start())
    cocotb.start_soon(_drive_roms(dut, hamming, twiddle))
    cocotb.start_soon(_drive_ddr_reads(dut, memories))
    await _reset(dut)

    await _wait_for(
        dut,
        lambda: int(dut.weights_ready.value) == 1 and int(dut.active_channel.value) == 0,
        2000,
        "Shared AI did not finish EEG weight prefetch",
    )
    assert int(dut.weight_prefetch_error.value) == 0
    cover("shared_ai.weight_prefetch")

    dut.vitals_updated.value = 1
    await RisingEdge(dut.sys_clk)
    dut.vitals_updated.value = 0

    await _wait_for(
        dut,
        lambda: dut.u_shared_cnn.bsram_addr.value.is_resolvable
        and int(dut.u_shared_cnn.bsram_addr.value) >= 100,
        2000,
        "Shared CNN did not read weights from the local cache",
    )
    cover("shared_ai.cache_to_cnn")

    samples = [
        int(round(12000.0 * math.sin(2.0 * math.pi * 8.0 * idx / 64.0)))
        for idx in range(2048)
    ]
    sent = 0
    while sent < len(samples):
        await RisingEdge(dut.sys_clk)
        if int(dut.eeg_ready.value):
            dut.eeg_sample.value = samples[sent] & 0xFFFF
            dut.eeg_valid.value = 1
            sent += 1
        else:
            dut.eeg_valid.value = 0
    await RisingEdge(dut.sys_clk)
    dut.eeg_valid.value = 0

    observed_class_valid = False
    for _ in range(220000):
        await RisingEdge(dut.sys_clk)
        if dut.u_shared_cnn.class_valid.value.is_resolvable and int(dut.u_shared_cnn.class_valid.value):
            observed_class_valid = True
        if observed_class_valid and int(dut.active_channel.value) == 1:
            break

    assert observed_class_valid, "Shared CNN did not produce class_valid for EEG slot"
    assert int(dut.active_channel.value) == 1, "Scheduler did not advance from EEG to ECG"
    cover("shared_ai.channel_advance")

    assert dut.final_class.value.is_resolvable
    assert dut.triggered_sensors.value.is_resolvable
    assert dut.confidence.value.is_resolvable
    cover("shared_ai.decision_update", final_class=int(dut.final_class.value))
