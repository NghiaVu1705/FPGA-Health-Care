import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge
from coverage.functional_coverage import cover


BIT_CYCLES = 10


async def reset(dut):
    dut.rst_n.value = 0
    dut.uart_rx.value = 1
    dut.dbg_data.value = 0
    dut.dbg_valid.value = 0
    for _ in range(8):
        await RisingEdge(dut.sys_clk)
    dut.rst_n.value = 1
    for _ in range(8):
        await RisingEdge(dut.sys_clk)


async def send_uart_byte(dut, value):
    dut.uart_rx.value = 0
    for _ in range(BIT_CYCLES):
        await RisingEdge(dut.sys_clk)
    for bit in range(8):
        dut.uart_rx.value = (value >> bit) & 1
        for _ in range(BIT_CYCLES):
            await RisingEdge(dut.sys_clk)
    dut.uart_rx.value = 1
    for _ in range(BIT_CYCLES):
        await RisingEdge(dut.sys_clk)


async def send_frame(dut, hi, lo, checksum=None):
    if checksum is None:
        checksum = hi ^ lo
    for byte in (0xAA, hi, lo, checksum):
        await send_uart_byte(dut, byte)


async def monitor_samples(dut, samples):
    while True:
        await RisingEdge(dut.sys_clk)
        if int(dut.emg_valid.value):
            samples.append(int(dut.emg_sample.value))


@cocotb.test()
async def test_uart_emg_frames_and_debug_tx(dut):
    cocotb.start_soon(Clock(dut.sys_clk, 100, unit="ns").start())
    await reset(dut)
    samples = []
    cocotb.start_soon(monitor_samples(dut, samples))

    await send_frame(dut, 0x12, 0x34)
    for _ in range(20):
        await RisingEdge(dut.sys_clk)
    assert samples[-1] == 0x1234
    cover("uart.valid_frame")

    count_before = len(samples)
    await send_frame(dut, 0x56, 0x78, checksum=0x00)
    for _ in range(40):
        await RisingEdge(dut.sys_clk)
    assert len(samples) == count_before
    cover("uart.bad_checksum")

    for byte in (0x00, 0x55, 0xFE):
        await send_uart_byte(dut, byte)
    await send_frame(dut, 0x22, 0x11)
    for _ in range(20):
        await RisingEdge(dut.sys_clk)
    assert samples[-1] == 0x2211
    cover("uart.resync_garbage")

    await send_frame(dut, 0xAB, 0xCD)
    for _ in range(20):
        await RisingEdge(dut.sys_clk)
    assert samples[-1] == 0xABCD
    await send_frame(dut, 0x01, 0x02)
    for _ in range(20):
        await RisingEdge(dut.sys_clk)
    assert samples[-1] == 0x0102
    cover("uart.back_to_back")

    assert int(dut.dbg_ready.value) == 1
    dut.dbg_data.value = 0x5A
    dut.dbg_valid.value = 1
    await RisingEdge(dut.sys_clk)
    dut.dbg_valid.value = 0
    await RisingEdge(dut.sys_clk)
    assert int(dut.dbg_ready.value) == 0
    for _ in range(140):
        await RisingEdge(dut.sys_clk)
    assert int(dut.dbg_ready.value) == 1
    cover("uart.debug_ready_busy")
