import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge
from coverage.functional_coverage import cover


@cocotb.test()
async def test_vendor_boundary_stubs(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.rst_n.value = 0
    dut.hamming_addr.value = 0
    dut.twiddle_addr.value = 0
    dut.fifo_wr_en.value = 0
    dut.fifo_rd_en.value = 0
    dut.fifo_data.value = 0
    dut.rgb_vs.value = 0
    dut.rgb_hs.value = 0
    dut.rgb_de.value = 0
    dut.rgb_r.value = 0
    dut.rgb_g.value = 0
    dut.rgb_b.value = 0
    for _ in range(4):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    for _ in range(4):
        await RisingEdge(dut.clk)

    dut.hamming_addr.value = 3
    dut.twiddle_addr.value = 2
    await RisingEdge(dut.clk)
    assert dut.hamming_data.value.is_resolvable
    assert dut.twiddle_data.value.is_resolvable
    cover("vendor.bsram_boundary")

    dut.fifo_data.value = 0xCAFE
    dut.fifo_wr_en.value = 1
    await RisingEdge(dut.clk)
    dut.fifo_wr_en.value = 0
    dut.fifo_rd_en.value = 1
    await RisingEdge(dut.clk)
    dut.fifo_rd_en.value = 0
    await RisingEdge(dut.clk)
    assert int(dut.fifo_q.value) == 0xCAFE
    cover("vendor.fifo_boundary")

    assert int(dut.pll_lock.value) == 1
    assert int(dut.pll_clk0.value) in (0, 1)
    cover("vendor.tmds_boundary")

    dut.rgb_de.value = 1
    dut.rgb_r.value = 0x01
    dut.rgb_g.value = 0x02
    dut.rgb_b.value = 0x03
    await RisingEdge(dut.clk)
    assert int(dut.tmds_data_p.value) == 0b101
    cover("vendor.dvi_boundary")
