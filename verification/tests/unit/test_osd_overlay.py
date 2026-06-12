import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge
from coverage.functional_coverage import cover

# osd_overlay pixel pipeline latency (OSD_LATENCY). Hold (hcount,vcount) past it.
OSD_LATENCY = 5


async def reset(dut):
    dut.rst_n.value = 0
    dut.de.value = 1
    dut.wave_pixel.value = 0x123456
    dut.class_out.value = 0
    dut.triggered_sensors.value = 0
    dut.confidence.value = 0
    dut.spo2_raw.value = 98
    dut.temp_raw.value = 72
    for _ in range(4):
        await RisingEdge(dut.pixel_clk)
    dut.rst_n.value = 1
    for _ in range(4):
        await RisingEdge(dut.pixel_clk)


async def rgb_at(dut, x, y):
    dut.hcount.value = x
    dut.vcount.value = y
    for _ in range(OSD_LATENCY + 2):
        await RisingEdge(dut.pixel_clk)
    return (int(dut.r_out.value) << 16) | (int(dut.g_out.value) << 8) | int(dut.b_out.value)


@cocotb.test()
async def test_osd_regions(dut):
    """Current layout: status banner rows 600..655 (STATUS px<400, CONF 400..799),
    sensor cards rows 656..719. Pick background pixels above the text band (y=610)."""
    cocotb.start_soon(Clock(dut.pixel_clk, 10, unit="ns").start())
    await reset(dut)

    # Status banner background colour (STATUS zone, x<400) follows class_out.
    for cls, color in ((2, 0xFF2222), (1, 0xFFAA00), (0, 0x00CC44)):
        dut.class_out.value = cls
        assert await rgb_at(dut, 100, 610) == color, f"status class {cls}"
    cover("display.osd_class_regions")

    # Sensor card background: EEG triggered -> active blue, else dark panel.
    dut.class_out.value = 0
    dut.triggered_sensors.value = 0b10000          # EEG trigger (bit 4)
    assert await rgb_at(dut, 100, 665) == 0x00AAFF, "eeg card active"
    dut.triggered_sensors.value = 0
    assert await rgb_at(dut, 100, 665) == 0x101820, "eeg card idle"
    cover("display.osd_sensor_regions")

    # Confidence banner zone (px 400..799) follows confidence (HIGH->green, LOW->gray).
    dut.confidence.value = 2
    assert await rgb_at(dut, 500, 610) == 0x00CC44, "conf high"
    dut.confidence.value = 0
    assert await rgb_at(dut, 500, 610) == 0x444444, "conf low gray"
    cover("display.osd_conf_vitals")
