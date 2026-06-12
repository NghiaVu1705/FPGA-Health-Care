import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge
from coverage.functional_coverage import cover


@cocotb.test()
async def test_vga_active_and_sync_regions(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.rst.value = 1
    for _ in range(4):
        await RisingEdge(dut.clk)
    dut.rst.value = 0

    saw_de = False
    saw_hs = False
    saw_vs = False
    for _ in range(120):
        await RisingEdge(dut.clk)
        saw_de = saw_de or bool(int(dut.de.value))
        saw_hs = saw_hs or bool(int(dut.hs.value))
        saw_vs = saw_vs or bool(int(dut.vs.value))

    assert saw_de
    assert saw_hs
    assert saw_vs
    cover("display.vga_de")
    cover("display.vga_hs_vs")
