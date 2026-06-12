"""Byte-exact parity: stft_top RTL vs the bit-exact software model.

Streams 2048 int16 samples through ``stft_top`` and asserts the emitted
32x32 = 1024-byte spectrogram is *identical* — every single byte — to
``software/preprocess/stft_transform.spectrogram``, the model the training
pipeline uses.  This is the contract that lets a model trained on
software-generated spectrograms see exactly what the FPGA produces at run time.

Unlike ``test_stft_top.py`` (a loose scipy-float sanity check), this is an
exact equality test.  It guards the four hardware quirks the model reproduces:

  * 16-bit Hamming multiply overflow (product wraps before ``>>> 8``),
  * stale twiddle — 1-cycle twiddle-ROM latency makes each butterfly use the
    *previous* butterfly's twiddle, threaded continuously across hops,
  * butterfly sum wraps to int32 *before* the per-stage ``>>> 1``,
  * windowed input cyclically rotated +1 before the bit-reversed FFT load
    (an off-by-one in stft_top's FFT-feed pipeline).

If this test fails after an RTL edit, the software model (and every spectrogram
the CNN was trained on) no longer matches silicon — treat it as a release
blocker, not a tolerance to loosen.
"""

from __future__ import annotations

import sys
from pathlib import Path

import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

PROJECT_ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(PROJECT_ROOT / "software"))
from preprocess.stft_transform import load_roms, spectrogram  # noqa: E402

HAMMING_HEX = PROJECT_ROOT / "rtl/gowin_bsram/hamming_coeff_rom.hex"
TWIDDLE_HEX = PROJECT_ROOT / "rtl/gowin_bsram/fft_twiddle_rom.hex"

N_SAMPLES = 2048
SPEC_BYTES = 1024


def _read_hex(path: Path) -> list[int]:
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
    """1-cycle synchronous ROM read — matches the Gowin BSRAM IP exactly."""
    dut.hamming_rom_data.value = 0
    dut.twiddle_rom_data.value = 0
    while True:
        await RisingEdge(dut.sys_clk)
        h_addr = dut.hamming_rom_addr.value
        t_addr = dut.twiddle_rom_addr.value
        dut.hamming_rom_data.value = hamming[int(h_addr) & 0x3F] if h_addr.is_resolvable else 0
        dut.twiddle_rom_data.value = twiddle[int(t_addr) & 0x1F] if t_addr.is_resolvable else 0


async def _run_frame(dut, samples) -> np.ndarray:
    """Reset, stream 2048 samples, return the 1024 emitted spectrogram bytes."""
    await _reset(dut)
    for s in samples:
        dut.sample_in.value = int(s) & 0xFFFF
        dut.sample_valid.value = 1
        await RisingEdge(dut.sys_clk)
    dut.sample_valid.value = 0

    observed: list[int] = []
    for _ in range(200000):
        await RisingEdge(dut.sys_clk)
        if int(dut.spec_valid.value):
            observed.append(int(dut.spec_out.value))
            if len(observed) == SPEC_BYTES:
                break
    assert len(observed) == SPEC_BYTES, f"timeout: only {len(observed)} of {SPEC_BYTES} bytes"
    return np.array(observed, dtype=np.uint8)


def _stimuli() -> list[tuple[str, np.ndarray]]:
    """Representative + adversarial inputs that exercise all four quirks."""
    n = np.arange(N_SAMPLES)
    raw: list[tuple[str, np.ndarray]] = [
        ("sine_amp400_bin8", np.rint(400.0 * np.sin(2 * np.pi * 8 * n / 64.0))),
        ("sine_amp20000_bin8", np.rint(20000.0 * np.sin(2 * np.pi * 8 * n / 64.0))),
        ("multitone_3_8_13", np.rint(
            300.0 * np.sin(2 * np.pi * 3 * n / 64.0)
            + 200.0 * np.sin(2 * np.pi * 8 * n / 64.0)
            + 150.0 * np.sin(2 * np.pi * 13 * n / 64.0))),
        ("dc_min_overflow", np.full(N_SAMPLES, -32768)),    # heavy 16-bit window overflow
        ("silence", np.zeros(N_SAMPLES)),
        ("random_seed0", np.random.default_rng(0).integers(-32768, 32768, size=N_SAMPLES)),
        ("random_seed1", np.random.default_rng(1).integers(-32768, 32768, size=N_SAMPLES)),
        ("random_seed2", np.random.default_rng(2).integers(-32768, 32768, size=N_SAMPLES)),
    ]
    return [(name, np.asarray(s).astype(np.int16)) for name, s in raw]


@cocotb.test()
async def test_stft_byte_exact_parity(dut):
    hamming = _read_hex(HAMMING_HEX)
    twiddle = _read_hex(TWIDDLE_HEX)
    ham_model, tw_model = load_roms(HAMMING_HEX, TWIDDLE_HEX)

    cocotb.start_soon(Clock(dut.sys_clk, 10, unit="ns").start())
    cocotb.start_soon(_drive_sync_roms(dut, hamming, twiddle))

    failures: list[str] = []
    for name, samples in _stimuli():
        rtl = await _run_frame(dut, samples)
        model = spectrogram(samples, ham_model, tw_model).reshape(-1).astype(np.uint8)
        exact = np.array_equal(rtl, model)
        if not exact:
            diff = rtl.astype(int) != model.astype(int)
            first = int(np.argmax(diff))
            failures.append(
                f"{name}: {int(diff.sum())} byte(s) differ; first @ byte {first} "
                f"(hop {first // 32}, bin {first % 32}) rtl={int(rtl[first])} "
                f"model={int(model[first])}, max|d|={int(np.abs(rtl.astype(int) - model.astype(int)).max())}")
        dut._log.info("parity %-18s : %s", name, "EXACT" if exact else "MISMATCH")

    assert not failures, "byte-exact STFT parity FAILED:\n" + "\n".join(failures)
