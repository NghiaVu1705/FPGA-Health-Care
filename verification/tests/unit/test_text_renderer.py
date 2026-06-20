from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge
from coverage.functional_coverage import cover

# text_renderer is a 2-stage pipeline (registered BSRAM font read -> bit-select).
PIPE = 2

# Canonical font ROM shipped with the RTL (95 glyphs x 16 rows, 1 byte/row).
FONT_HEX = Path(__file__).resolve().parents[3] / "rtl" / "display" / "font8x16.hex"


def load_font():
    rows = []
    for line in FONT_HEX.read_text().splitlines():
        line = line.strip()
        if line:
            rows.append(int(line, 16))
    return rows


async def _sample(dut, hx, hy):
    """Drive (hcount,vcount), wait past the pipeline, return (pixel_on, pixel_out)."""
    dut.hcount.value = hx
    dut.vcount.value = hy
    for _ in range(PIPE + 1):
        await RisingEdge(dut.pixel_clk)
    return int(dut.pixel_on.value), int(dut.pixel_out.value)


@cocotb.test()
async def test_text_renderer_cell_pixels(dut):
    """Render glyph 'A' from the REAL font8x16.hex and verify every pixel of two
    representative rows matches the font bitmap (MSB = leftmost), plus background
    and out-of-cell behaviour."""
    cocotb.start_soon(Clock(dut.pixel_clk, 10, unit="ns").start())

    font = load_font()
    idx = 0x41 - 0x20                     # 'A' -> glyph index 33
    glyph = font[idx * 16:(idx + 1) * 16]
    assert glyph[7] == 0xFE and glyph[2] == 0x10, f"unexpected font 'A': {glyph}"

    dut.rst_n.value = 0
    dut.hcount.value = 0
    dut.vcount.value = 0
    dut.char_ascii.value = 0x41
    dut.char_x.value = 10
    dut.char_y.value = 20
    dut.scale.value = 0                   # 8x16 cell
    dut.fg_color.value = 0xABCDEF
    dut.bg_color.value = 0x010203
    dut.bg_en.value = 1
    for _ in range(4):
        await RisingEdge(dut.pixel_clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.pixel_clk)

    # Deposit the real glyph rows into the font ROM (COCOTB_SIM skips $readmemh).
    for r in range(16):
        dut.font_rom[idx * 16 + r].value = glyph[r]
    await RisingEdge(dut.pixel_clk)

    # Verify two full rows of 'A' against the real bitmap, all 8 columns each.
    # MSB is the leftmost pixel: glyph pixel on when row_byte[7 - col] == 1.
    for row in (2, 7):
        row_byte = glyph[row]
        for col in range(8):
            expect_on = (row_byte >> (7 - col)) & 1
            on, rgb = await _sample(dut, 10 + col, 20 + row)
            assert on == expect_on, (
                f"row {row} col {col}: pixel_on={on} expected={expect_on} "
                f"(byte=0x{row_byte:02x})"
            )
            if expect_on:
                assert rgb == 0xABCDEF, f"glyph fg wrong: {rgb:06x}"
            else:
                assert rgb == 0x010203, f"glyph bg wrong: {rgb:06x}"
    cover("display.text_cell_on_off")
    cover("display.text_font_content")

    # Outside the character cell -> transparent.
    on, rgb = await _sample(dut, 200, 200)
    assert on == 0 and rgb == 0x000000, f"outside cell: on={on} rgb={rgb:06x}"
