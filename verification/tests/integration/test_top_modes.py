import os

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer
from coverage.functional_coverage import cover


async def reset(dut):
    dut.rst_n.value = 0
    dut.case_next_n.value = 1
    dut.uart_rx_emg.value = 1
    dut.spi_sck.value = 0
    dut.spi_mosi.value = 0
    dut.spi_cs_n.value = 1
    dut.i2c_scl.value = 1
    dut.i2c_sda.value = 1
    for _ in range(12):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    for _ in range(40):
        await RisingEdge(dut.clk)


@cocotb.test()
async def test_top_lite_or_full_smoke(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset(dut)

    cov_file = os.environ.get("FUNCTIONAL_COVERAGE_FILE", "")
    if "top_full_lint" in cov_file:
        assert dut.tmds_clk_p_0.value.is_resolvable
        cover("top.full_elaboration")
        return

    cover("top.lite_elaboration")

    dut.case_next_n.value = 0
    await RisingEdge(dut.clk)
    dut.case_next_n.value = 1
    dut.spi_cs_n.value = 0
    dut.spi_mosi.value = 1
    for _ in range(4):
        dut.spi_sck.value = 1
        await RisingEdge(dut.clk)
        dut.spi_sck.value = 0
        await RisingEdge(dut.clk)
    dut.spi_cs_n.value = 1
    cover("top.sensor_boundary")

    values = []
    for _ in range(80):
        await Timer(5, unit="ns")
        values.append(int(dut.tmds_clk_p_0.value))
    assert len(set(values)) == 2
    assert dut.tmds_d_p_0.value.is_resolvable
    cover("top.dvi_boundary")
