"""weight_cache_512x8: registered (1-cycle, BSRAM) read-back + write/read aliasing.

The cache was changed from async to a registered read so it maps to a Gowin BSRAM
(it was ~4096 FF + a 512:1 LUT mux as async). cnn_top's load FSM compensates with
+1 cycle. This checks the registered-read contract directly.
"""

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

from coverage.functional_coverage import cover


async def _clk(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.rst_n.value = 1
    dut.wr_en.value = 0
    dut.wr_addr.value = 0
    dut.wr_data.value = 0
    dut.rd_addr.value = 0
    await RisingEdge(dut.clk)


async def _write(dut, addr, data):
    dut.wr_en.value = 1
    dut.wr_addr.value = addr
    dut.wr_data.value = data
    await RisingEdge(dut.clk)
    dut.wr_en.value = 0


async def _read(dut, addr):
    # Registered read: present address, value lands one clock later.
    dut.rd_addr.value = addr
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    return int(dut.rd_data.value)


@cocotb.test()
async def test_registered_readback(dut):
    await _clk(dut)

    # Write a deterministic + random set of byte addresses, then read each back.
    ref = {}
    for addr in (0, 1, 255, 256, 511):
        data = (addr * 7 + 3) & 0xFF
        await _write(dut, addr, data)
        ref[addr] = data
    rng = random.Random(1234)
    for _ in range(32):
        addr = rng.randrange(512)
        data = rng.randrange(256)
        await _write(dut, addr, data)
        ref[addr] = data

    for addr, data in ref.items():
        got = await _read(dut, addr)
        assert got == data, f"addr {addr}: read {got} != {data}"
    cover("weight_cache.readback")

    # Write-then-immediate-read of a fresh address still returns the new byte
    # (after the 1-cycle latency), confirming no stale read.
    await _write(dut, 100, 0xA5)
    assert await _read(dut, 100) == 0xA5
    cover("weight_cache.write_read")
