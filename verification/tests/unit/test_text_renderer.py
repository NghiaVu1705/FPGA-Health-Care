import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge
from coverage.functional_coverage import cover

# text_renderer is a 2-stage pipeline (registered BSRAM font read -> bit-select).
PIPE = 2


async def _sample(dut, hx, hy):
    """Drive (hcount,vcount), wait past the pipeline, return (pixel_on, pixel_out)."""
    dut.hcount.value = hx
    dut.vcount.value = hy
    for _ in range(PIPE + 1):
        await RisingEdge(dut.pixel_clk)
    return int(dut.pixel_on.value), int(dut.pixel_out.value)


@cocotb.test()
async def test_text_renderer_cell_pixels(dut):
    cocotb.start_soon(Clock(dut.pixel_clk, 10, unit="ns").start())
    dut.rst_n.value = 0
    dut.hcount.value = 0
    dut.vcount.value = 0
    dut.char_ascii.value = 0x41          # 'A' -> char_idx = 0x41-0x20 = 33
    dut.char_x.value = 10
    dut.char_y.value = 20
    dut.scale.value = 0                  # 8x16 cell
    dut.fg_color.value = 0xABCDEF
    dut.bg_color.value = 0x010203
    dut.bg_en.value = 1
    for _ in range(4):
        await RisingEdge(dut.pixel_clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.pixel_clk)

    # Glyph 'A' row 0 = 0x80 (only the leftmost pixel on). Deposit + let it settle
    # before the registered ROM read samples it.
    dut.font_rom[33 * 16 + 0].value = 0x80
    await RisingEdge(dut.pixel_clk)

    # (10,20) = cell col 0, row 0, bit 0x80[7] = 1 -> glyph pixel (fg).
    on, rgb = await _sample(dut, 10, 20)
    assert on == 1 and rgb == 0xABCDEF, f"glyph pixel: on={on} rgb={rgb:06x}"

    # (11,20) = cell col 1, bit 0x80[6] = 0 -> background (bg_en=1).
    on, rgb = await _sample(dut, 11, 20)
    assert on == 0 and rgb == 0x010203, f"bg pixel: on={on} rgb={rgb:06x}"

    # (50,50) = outside the character cell -> transparent (0).
    on, rgb = await _sample(dut, 50, 50)
    assert on == 0 and rgb == 0x000000, f"outside cell: on={on} rgb={rgb:06x}"
    cover("display.text_cell_on_off")
