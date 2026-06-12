import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge
from coverage.functional_coverage import cover


async def reset(dut):
    dut.rst_n.value = 0
    dut.pixel_rst_n.value = 0
    dut.eeg_valid.value = 0
    dut.ecg_valid.value = 0
    dut.emg_valid.value = 0
    dut.de.value = 0
    dut.hcount.value = 0
    dut.vcount.value = 0
    for _ in range(6):
        await RisingEdge(dut.sys_clk)
    dut.rst_n.value = 1
    dut.pixel_rst_n.value = 1
    for _ in range(6):
        await RisingEdge(dut.sys_clk)


async def sample_pixel(dut, x, y):
    # Hold (hcount,vcount) constant past the 5-stage pixel pipeline so pixel_out
    # settles to this coordinate's colour.
    dut.hcount.value = x
    dut.vcount.value = y
    dut.de.value = 1
    for _ in range(7):
        await RisingEdge(dut.pixel_clk)
    return int(dut.pixel_out.value)


@cocotb.test()
async def test_waveform_regions(dut):
    cocotb.start_soon(Clock(dut.sys_clk, 10, unit="ns").start())
    cocotb.start_soon(Clock(dut.pixel_clk, 10, unit="ns").start())
    await reset(dut)

    for _ in range(2048):
        dut.eeg_sample.value = 128
        dut.ecg_sample.value = 128
        dut.emg_sample.value = 128
        dut.eeg_valid.value = 1
        dut.ecg_valid.value = 1
        dut.emg_valid.value = 1
        await RisingEdge(dut.sys_clk)
    dut.eeg_valid.value = 0
    dut.ecg_valid.value = 0
    dut.emg_valid.value = 0
    for _ in range(8):
        await RisingEdge(dut.pixel_clk)

    # Layout: 3 lanes x 200px (EEG 0..199, ECG 200..399, EMG 400..599).
    # sample 128 -> scaled = 128*200/256 = 100 -> beam y = lane_top + 199 - 100.
    assert await sample_pixel(dut, 7, 99) == 0x00FF88
    cover("display.wave_eeg")
    assert await sample_pixel(dut, 7, 299) == 0xFF4444
    cover("display.wave_ecg")
    assert await sample_pixel(dut, 7, 499) == 0x4488FF
    cover("display.wave_emg")

    # Vertical grid line every 32 px (hcount[4:0]==0); plain background elsewhere.
    assert await sample_pixel(dut, 32, 10) == 0x222222
    cover("display.wave_grid")
    assert await sample_pixel(dut, 17, 10) == 0x111111
    cover("display.wave_bg")
