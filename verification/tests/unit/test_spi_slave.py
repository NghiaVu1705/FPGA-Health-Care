import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge
from coverage.functional_coverage import cover


async def reset(dut):
    dut.rst_n.value = 0
    dut.spi_sck.value = 0
    dut.spi_mosi.value = 0
    dut.spi_cs_n.value = 1
    for _ in range(8):
        await RisingEdge(dut.sys_clk)
    dut.rst_n.value = 1
    for _ in range(4):
        await RisingEdge(dut.sys_clk)


async def spi_frame(dut, frame):
    observed = None
    dut.spi_cs_n.value = 0
    for bit in range(15, -1, -1):
        dut.spi_mosi.value = (frame >> bit) & 1
        for _ in range(3):
            await RisingEdge(dut.sys_clk)
        dut.spi_sck.value = 1
        for _ in range(4):
            await RisingEdge(dut.sys_clk)
            if int(dut.rx_valid.value):
                observed = (int(dut.channel.value), dut.rx_data.value.signed_integer)
        dut.spi_sck.value = 0
        for _ in range(4):
            await RisingEdge(dut.sys_clk)
            if int(dut.rx_valid.value):
                observed = (int(dut.channel.value), dut.rx_data.value.signed_integer)
    dut.spi_cs_n.value = 1
    for _ in range(4):
        await RisingEdge(dut.sys_clk)
        if int(dut.rx_valid.value):
            observed = (int(dut.channel.value), dut.rx_data.value.signed_integer)
    return observed


@cocotb.test()
async def test_spi_channel_samples_abort_and_back_to_back(dut):
    cocotb.start_soon(Clock(dut.sys_clk, 10, unit="ns").start())
    await reset(dut)

    channel, sample = await spi_frame(dut, 0x0000)
    assert channel == 0
    assert sample == -2048
    cover("spi.eeg_channel")
    cover("spi.adc_min")

    channel, sample = await spi_frame(dut, 0x0800)
    assert channel == 0
    assert sample == 0
    cover("spi.adc_mid")

    channel, sample = await spi_frame(dut, 0x8FFF)
    assert channel == 1
    assert sample == 2047
    cover("spi.ecg_channel")
    cover("spi.adc_max")

    dut.spi_cs_n.value = 0
    for bit in range(7, -1, -1):
        dut.spi_mosi.value = (0xA5 >> bit) & 1
        await RisingEdge(dut.sys_clk)
        dut.spi_sck.value = 1
        await RisingEdge(dut.sys_clk)
        dut.spi_sck.value = 0
        await RisingEdge(dut.sys_clk)
    dut.spi_cs_n.value = 1
    for _ in range(8):
        await RisingEdge(dut.sys_clk)
    assert int(dut.rx_valid.value) == 0
    cover("spi.cs_abort")

    assert await spi_frame(dut, 0x0001) is not None
    assert await spi_frame(dut, 0x0002) is not None
    cover("spi.back_to_back")
