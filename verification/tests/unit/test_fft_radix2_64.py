from pathlib import Path

import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge
from coverage.functional_coverage import cover


PROJECT_ROOT = Path(__file__).resolve().parents[3]
TWIDDLE_HEX = PROJECT_ROOT / "rtl/gowin_bsram/fft_twiddle_rom.hex"


def read_twiddle():
    return [int(line.strip(), 16) for line in TWIDDLE_HEX.read_text().splitlines() if line.strip()]


async def drive_twiddle(dut, data):
    dut.twiddle_data.value = 0
    while True:
        await RisingEdge(dut.sys_clk)
        addr = dut.twiddle_addr_out.value
        dut.twiddle_data.value = data[int(addr) & 0x1F] if addr.is_resolvable else 0


async def reset(dut):
    dut.rst_n.value = 0
    dut.x_in.value = 0
    dut.x_valid.value = 0
    dut.frame_start.value = 0
    for _ in range(8):
        await RisingEdge(dut.sys_clk)
    dut.rst_n.value = 1
    for _ in range(4):
        await RisingEdge(dut.sys_clk)


async def run_frame(dut, samples):
    dut.frame_start.value = 1
    await RisingEdge(dut.sys_clk)
    dut.frame_start.value = 0
    for sample in samples:
        dut.x_in.value = int(sample) & 0xFFFF
        dut.x_valid.value = 1
        await RisingEdge(dut.sys_clk)
    dut.x_valid.value = 0

    out = []
    for _ in range(1600):
        await RisingEdge(dut.sys_clk)
        if int(dut.bin_valid.value):
            out.append((dut.re_out.value.signed_integer, dut.im_out.value.signed_integer))
        if int(dut.frame_done.value):
            break
    assert len(out) == 64
    return out


@cocotb.test()
async def test_fft_impulse_dc_sine_and_reset(dut):
    twiddle = read_twiddle()
    cocotb.start_soon(Clock(dut.sys_clk, 10, unit="ns").start())
    cocotb.start_soon(drive_twiddle(dut, twiddle))
    await reset(dut)
    cover("fft.reset")

    impulse = [0] * 64
    impulse[0] = 1024
    impulse_out = await run_frame(dut, impulse)
    assert max(abs(re) + abs(im) for re, im in impulse_out) > 0
    cover("fft.impulse")

    dc_out = await run_frame(dut, [1024] * 64)
    mags = [abs(re) + abs(im) for re, im in dc_out]
    assert max(mags) > 0
    cover("fft.dc")

    sine = np.rint(2048 * np.sin(2 * np.pi * 5 * np.arange(64) / 64)).astype(np.int16)
    sine_out = await run_frame(dut, sine)
    sine_mags = [abs(re) + abs(im) for re, im in sine_out]
    assert max(sine_mags) > 0
    cover("fft.sine_bin")
