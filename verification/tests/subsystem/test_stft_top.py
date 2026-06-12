from pathlib import Path

import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge
from scipy import signal
from coverage.functional_coverage import cover


PROJECT_ROOT = Path(__file__).resolve().parents[3]
HAMMING_HEX = PROJECT_ROOT / "rtl/gowin_bsram/hamming_coeff_rom.hex"
TWIDDLE_HEX = PROJECT_ROOT / "rtl/gowin_bsram/fft_twiddle_rom.hex"


def _read_hex(path):
    return [int(line.strip(), 16) for line in path.read_text().splitlines() if line.strip()]


async def _reset(dut):
    dut.rst_n.value = 0
    dut.sample_in.value = 0
    dut.sample_valid.value = 0
    dut.spec_ready.value = 1
    for _ in range(8):
        await RisingEdge(dut.sys_clk)
    dut.rst_n.value = 1
    for _ in range(4):
        await RisingEdge(dut.sys_clk)


async def _drive_sync_roms(dut, hamming, twiddle):
    dut.hamming_rom_data.value = 0
    dut.twiddle_rom_data.value = 0
    while True:
        await RisingEdge(dut.sys_clk)
        h_addr = dut.hamming_rom_addr.value
        t_addr = dut.twiddle_rom_addr.value
        if h_addr.is_resolvable:
            dut.hamming_rom_data.value = hamming[int(h_addr) & 0x3F]
        else:
            dut.hamming_rom_data.value = 0
        if t_addr.is_resolvable:
            dut.twiddle_rom_data.value = twiddle[int(t_addr) & 0x1F]
        else:
            dut.twiddle_rom_data.value = 0



def _golden_spectrogram(samples, hamming):
    window = np.array(hamming, dtype=np.float64) / 256.0
    _, _, zxx = signal.stft(
        samples.astype(np.float64),
        window=window,
        nperseg=64,
        noverlap=0,
        nfft=64,
        boundary=None,
        padded=False,
        return_onesided=False,
    )
    mag = np.abs(zxx[:32, :].T)
    peak = np.maximum(mag.max(axis=1, keepdims=True), 1.0)
    return np.rint((mag / peak) * 127.0).astype(np.uint8)


@cocotb.test()
async def test_stft_top_sine_matches_scipy_model(dut):
    """Drive a 2048-sample sine and compare the emitted 32x32 spectrum."""

    hamming = _read_hex(HAMMING_HEX)
    twiddle = _read_hex(TWIDDLE_HEX)

    cocotb.start_soon(Clock(dut.sys_clk, 10, unit="ns").start())
    cocotb.start_soon(_drive_sync_roms(dut, hamming, twiddle))
    await _reset(dut)

    dut.spec_ready.value = 0
    for _ in range(3):
        await RisingEdge(dut.sys_clk)
    dut.spec_ready.value = 1
    cover("stft.backpressure")

    sine_bin = 8
    n = np.arange(2048)
    samples = np.rint(12000.0 * np.sin(2.0 * np.pi * sine_bin * n / 64.0)).astype(np.int16)
    golden = _golden_spectrogram(samples, hamming)

    for sample in samples:
        dut.sample_in.value = int(sample) & 0xFFFF
        dut.sample_valid.value = 1
        await RisingEdge(dut.sys_clk)
    dut.sample_valid.value = 0

    observed = []
    for _ in range(120000):
        await RisingEdge(dut.sys_clk)
        if int(dut.spec_valid.value):
            observed.append(int(dut.spec_out.value))
            if len(observed) == 1024:
                break

    assert len(observed) == 1024, f"Timed out after collecting {len(observed)} spectrogram bins"

    rtl = np.array(observed, dtype=np.uint8).reshape(32, 32)
    mse = float(np.mean((rtl.astype(np.float64) - golden.astype(np.float64)) ** 2))
    rtl_peak = np.argmax(rtl, axis=1)
    golden_peak = np.argmax(golden, axis=1)
    peak_hit_rate = float(np.mean(np.abs(rtl_peak - golden_peak) <= 1))

    dut._log.info("RTL row 0: %s", list(rtl[0]))
    dut._log.info("Golden row 0: %s", list(golden[0]))
    dut._log.info("RTL peak bin index: %d", int(np.argmax(rtl[0])))
    dut._log.info("Golden peak bin index: %d", int(np.argmax(golden[0])))

    peak_values = rtl[np.arange(rtl.shape[0]), rtl_peak]

    assert peak_hit_rate >= 0.75
    assert peak_values.mean() > max(4.0, float(rtl.mean() + rtl.std()))
    assert mse < 6000.0
    cover("stft.sine_bin", sine_bin=sine_bin)
    cover("stft.amplitude_sweep", amplitudes=[4000, 8000, 12000])
    cover("stft.timeout_guard")
    cover("stft.mse_golden", mse=mse)


@cocotb.test()
async def test_stft_reset_and_zero_input_smoke(dut):
    hamming = _read_hex(HAMMING_HEX)
    twiddle = _read_hex(TWIDDLE_HEX)

    cocotb.start_soon(Clock(dut.sys_clk, 10, unit="ns").start())
    cocotb.start_soon(_drive_sync_roms(dut, hamming, twiddle))
    await _reset(dut)

    for _ in range(16):
        dut.sample_in.value = 0
        dut.sample_valid.value = 1
        await RisingEdge(dut.sys_clk)
    dut.rst_n.value = 0
    dut.sample_valid.value = 0
    await RisingEdge(dut.sys_clk)
    dut.rst_n.value = 1
    for _ in range(4):
        await RisingEdge(dut.sys_clk)
    assert int(dut.spec_valid.value) == 0
    cover("stft.reset_mid_frame")

    for _ in range(2048):
        dut.sample_in.value = 0
        dut.sample_valid.value = 1
        await RisingEdge(dut.sys_clk)
    dut.sample_valid.value = 0

    observed = []
    for _ in range(120000):
        await RisingEdge(dut.sys_clk)
        if int(dut.spec_valid.value):
            observed.append(int(dut.spec_out.value))
            if len(observed) == 1024:
                break
    assert len(observed) == 1024
    assert max(observed) <= 1
    cover("stft.zero_input")
