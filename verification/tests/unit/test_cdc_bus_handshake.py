"""Sim-level verification of cdc_bus_handshake.

Drives src_data + src_update on src_clk (10 ns) and observes dst_data +
dst_update on dst_clk (13.5 ns, i.e. roughly the 74 MHz pixel_clk used in
top_shared_ai). Verifies:
  - atomicity: every dst_data sample equals the src_data snapshot at the time
    of the most recent src_update (no torn bits between updates)
  - dst_update pulses exactly once per src_update
  - no spurious dst_update without a preceding src_update
  - reset behaviour: both src_data_r and dst_data start zero
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from coverage.functional_coverage import cover


async def _reset(dut):
    dut.src_rst_n.value = 0
    dut.dst_rst_n.value = 0
    dut.src_data.value = 0
    dut.src_update.value = 0
    for _ in range(20):
        await Timer(2, unit="ns")
    dut.src_rst_n.value = 1
    dut.dst_rst_n.value = 1
    for _ in range(20):
        await Timer(2, unit="ns")


@cocotb.test()
async def test_cdc_bus_handshake_atomic_transfer(dut):
    cocotb.start_soon(Clock(dut.src_clk, 10, unit="ns").start())   # 100 MHz
    cocotb.start_soon(Clock(dut.dst_clk, 13, unit="ns").start())   # ~76.9 MHz, near pixel_clk
    await _reset(dut)
    # Initial dst_data should be all-zero
    await RisingEdge(dut.dst_clk)
    assert int(dut.dst_data.value) == 0
    assert int(dut.dst_update.value) == 0

    sent_values = [0x1A5, 0x05A, 0x100, 0x0FF, 0x07E, 0x111, 0x0A5, 0x123]

    pulses_dst = 0
    observed_values = []
    deadline_cycles_per_send = 80
    expected_pulses = len(sent_values)

    # Driver coroutine: drives one src_update per iteration with stable data
    async def driver():
        for value in sent_values:
            await RisingEdge(dut.src_clk)
            dut.src_data.value = value
            dut.src_update.value = 1
            await RisingEdge(dut.src_clk)
            dut.src_update.value = 0
            for _ in range(20):
                await RisingEdge(dut.src_clk)
    cocotb.start_soon(driver())

    # Monitor dst side
    cycles = 0
    while pulses_dst < expected_pulses and cycles < expected_pulses * deadline_cycles_per_send:
        await RisingEdge(dut.dst_clk)
        if int(dut.dst_update.value):
            pulses_dst += 1
            observed_values.append(int(dut.dst_data.value))
        cycles += 1

    assert pulses_dst == expected_pulses, (
        f"expected {expected_pulses} dst_update pulses, got {pulses_dst}"
    )
    assert observed_values == sent_values, (
        f"atomicity broken: sent={sent_values}, observed={observed_values}"
    )
    # Negative check: ensure no spurious dst_update pulses occurred after the
    # last expected transfer for at least 50 dst cycles.
    spurious = 0
    for _ in range(50):
        await RisingEdge(dut.dst_clk)
        if int(dut.dst_update.value):
            spurious += 1
    assert spurious == 0, "spurious dst_update after stable state"
    cover("cdc.bus_handshake_atomic")


@cocotb.test()
async def test_cdc_bus_handshake_reset_holds_zero(dut):
    cocotb.start_soon(Clock(dut.src_clk, 10, unit="ns").start())
    cocotb.start_soon(Clock(dut.dst_clk, 13, unit="ns").start())
    await _reset(dut)
    # Hold reset while attempting to update — outputs must stay 0
    dut.src_rst_n.value = 0
    dut.dst_rst_n.value = 0
    dut.src_data.value = 0xAA
    dut.src_update.value = 1
    for _ in range(10):
        await RisingEdge(dut.src_clk)
    assert int(dut.dst_data.value) == 0
    assert int(dut.dst_update.value) == 0
    dut.src_update.value = 0
    cover("cdc.bus_handshake_reset")
