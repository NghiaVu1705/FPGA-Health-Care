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


async def clock_byte(dut, value):
    """Clock 8 data bits (MSB first) then the 9th (ACK) clock.

    During the 9th SCL-high the master releases SDA; a compliant slave pulls SDA
    low for the whole pulse. Returns the sampled ACK bit (0 = ACK, 1 = NAK).
    """
    for bit in range(7, -1, -1):
        dut.scl.value = 0
        dut.sda_drive_en.value = 1
        dut.sda_drive.value = (value >> bit) & 1
        await wait_cycles(dut)
        dut.scl.value = 1
        await wait_cycles(dut)

    # 9th clock: release SDA so the slave can drive ACK.
    dut.scl.value = 0
    dut.sda_drive_en.value = 0
    dut.sda_drive.value = 1
    await wait_cycles(dut, 6)          # let the 8th fall propagate + slave assert ACK
    dut.scl.value = 1
    await wait_cycles(dut, 6)          # 9th SCL high — ACK must be held here
    ack = int(dut.sda_line.value)      # 0 = slave pulled low (ACK), 1 = released (NAK)
    dut.scl.value = 0
    await wait_cycles(dut)
    dut.sda_drive_en.value = 1
    dut.sda_drive.value = 1
    await wait_cycles(dut)
    return ack


async def write_register(dut, address_byte, reg_addr, data):
    """Full write transaction. Returns the (addr, reg, data) ACK bits."""
    await start_cond(dut)
    a = await clock_byte(dut, address_byte)
    r = await clock_byte(dut, reg_addr)
    d = await clock_byte(dut, data)
    await stop_cond(dut)
    await wait_cycles(dut, 10)
    return a, r, d


@cocotb.test()
async def test_i2c_register_writes_and_recovery(dut):
    cocotb.start_soon(Clock(dut.sys_clk, 10, unit="ns").start())
    await reset(dut)

    assert int(dut.spo2_raw.value) == 98
    assert int(dut.temp_raw.value) == 72
    cover("i2c.reset_defaults")

    # Real bit-level write to the SpO2 register. Verify the stored value AND that
    # the slave holds ACK (SDA low) through the 9th SCL pulse on every byte.
    a, r, d = await write_register(dut, 0x90, 0x00, 91)
    assert int(dut.spo2_raw.value) == 91
    assert (a, r, d) == (0, 0, 0), f"slave must ACK each byte, got {(a, r, d)}"
    cover("i2c.write_spo2")
    cover("i2c.ack_held_9th_clock")

    a, r, d = await write_register(dut, 0x90, 0x01, 79)
    assert int(dut.temp_raw.value) == 79
    assert (a, r, d) == (0, 0, 0)
    cover("i2c.write_temp")

    # Wrong slave address (0x92 >> 1 = 0x49): slave must NAK and leave vitals alone.
    old_spo2 = int(dut.spo2_raw.value)
    await start_cond(dut)
    a = await clock_byte(dut, 0x92)
    await stop_cond(dut)
    await wait_cycles(dut, 10)
    assert int(dut.spo2_raw.value) == old_spo2
    assert a == 1, f"unmatched address must NAK, got {a}"
    cover("i2c.invalid_address")

    # Unknown register (0x7F): bytes are still ACKed at protocol level but the
    # write is ignored, so vitals stay unchanged.
    old_spo2 = int(dut.spo2_raw.value)
    old_temp = int(dut.temp_raw.value)
    a, r, d = await write_register(dut, 0x90, 0x7F, 33)
    assert int(dut.spo2_raw.value) == old_spo2
    assert int(dut.temp_raw.value) == old_temp
    assert (a, r, d) == (0, 0, 0)
    cover("i2c.invalid_register")

    # Repeated start / stop recovery.
    await start_cond(dut)
    await clock_byte(dut, 0x90)
    await clock_byte(dut, 0x00)
    await start_cond(dut)
    await stop_cond(dut)
    await wait_cycles(dut, 10)
    cover("i2c.repeated_start_stop")
