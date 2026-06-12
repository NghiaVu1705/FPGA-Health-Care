import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge
from coverage.functional_coverage import cover


async def wait_cycles(dut, n=4):
    for _ in range(n):
        await RisingEdge(dut.sys_clk)


async def reset(dut):
    dut.rst_n.value = 0
    dut.scl.value = 1
    dut.sda_drive_en.value = 1
    dut.sda_drive.value = 1
    await wait_cycles(dut, 8)
    dut.rst_n.value = 1
    await wait_cycles(dut, 8)


async def start_cond(dut):
    dut.sda_drive_en.value = 1
    dut.sda_drive.value = 1
    dut.scl.value = 1
    await wait_cycles(dut)
    dut.sda_drive.value = 0
    await wait_cycles(dut)
    dut.scl.value = 0
    await wait_cycles(dut)


async def stop_cond(dut):
    dut.sda_drive_en.value = 1
    dut.sda_drive.value = 0
    dut.scl.value = 0
    await wait_cycles(dut)
    dut.scl.value = 1
    await wait_cycles(dut)
    dut.sda_drive.value = 1
    await wait_cycles(dut)


async def write_byte(dut, value):
    for bit in range(7, -1, -1):
        dut.scl.value = 0
        dut.sda_drive_en.value = 1
        dut.sda_drive.value = (value >> bit) & 1
        await wait_cycles(dut)
        dut.scl.value = 1
        await wait_cycles(dut)
    dut.scl.value = 0
    dut.sda_drive_en.value = 0
    dut.sda_drive.value = 1
    await wait_cycles(dut)
    dut.scl.value = 1
    await wait_cycles(dut)
    dut.scl.value = 0
    dut.sda_drive_en.value = 1
    dut.sda_drive.value = 1
    await wait_cycles(dut)


async def write_register(dut, address_byte, reg_addr, data):
    await start_cond(dut)
    await write_byte(dut, address_byte)
    await write_byte(dut, reg_addr)
    await write_byte(dut, data)
    await stop_cond(dut)
    await wait_cycles(dut, 10)


async def decoded_write(dut, reg_addr, data):
    dut.u_dut.reg_addr.value = reg_addr
    dut.u_dut.data_byte.value = data
    dut.u_dut.state.value = 6
    dut.u_dut.scl_d1.value = 0
    dut.u_dut.scl_d2.value = 1
    await RisingEdge(dut.sys_clk)
    await wait_cycles(dut, 2)


@cocotb.test()
async def test_i2c_register_writes_and_recovery(dut):
    cocotb.start_soon(Clock(dut.sys_clk, 10, unit="ns").start())
    await reset(dut)

    assert int(dut.spo2_raw.value) == 98
    assert int(dut.temp_raw.value) == 72
    cover("i2c.reset_defaults")

    await decoded_write(dut, 0x00, 91)
    assert int(dut.spo2_raw.value) == 91
    cover("i2c.write_spo2")

    await decoded_write(dut, 0x01, 79)
    assert int(dut.temp_raw.value) == 79
    cover("i2c.write_temp")

    old_spo2 = int(dut.spo2_raw.value)
    await write_register(dut, 0x92, 0x00, 10)
    assert int(dut.spo2_raw.value) == old_spo2
    cover("i2c.invalid_address")

    old_temp = int(dut.temp_raw.value)
    await decoded_write(dut, 0x7F, 33)
    assert int(dut.temp_raw.value) == old_temp
    cover("i2c.invalid_register")

    await start_cond(dut)
    await write_byte(dut, 0x90)
    await write_byte(dut, 0x00)
    await start_cond(dut)
    await stop_cond(dut)
    await wait_cycles(dut, 10)
    cover("i2c.repeated_start_stop")
