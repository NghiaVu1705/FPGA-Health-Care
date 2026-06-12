import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from coverage.functional_coverage import cover


def beat_word(beat):
    value = 0
    for i in range(32):
        value |= ((beat * 32 + i) & 0xFF) << (i * 8)
    return value


async def reset(dut):
    dut.rst_n.value = 0
    dut.start.value = 0
    dut.base_addr.value = 0
    dut.ddr_cmd_ready.value = 0
    dut.ddr_rd_data.value = 0
    dut.ddr_rd_data_valid.value = 0
    dut.ddr_rd_data_end.value = 0
    for _ in range(5):
        await RisingEdge(dut.sys_clk)
    dut.rst_n.value = 1
    for _ in range(2):
        await RisingEdge(dut.sys_clk)


@cocotb.test()
async def test_ddr3_weight_prefetcher_reads_512_bytes(dut):
    cocotb.start_soon(Clock(dut.sys_clk, 10, unit="ns").start())
    await reset(dut)

    writes = {}
    cmd_addrs = []
    read_beats_sent = 0

    dut.base_addr.value = 0x1000
    dut.ddr_cmd_ready.value = 1
    dut.start.value = 1
    await RisingEdge(dut.sys_clk)
    dut.start.value = 0

    for _ in range(2000):
        await RisingEdge(dut.sys_clk)

        if int(dut.ddr_cmd_en.value):
            cmd_addrs.append(int(dut.ddr_addr.value))

        if len(cmd_addrs) > read_beats_sent and not int(dut.ddr_rd_data_valid.value):
            dut.ddr_rd_data.value = beat_word(read_beats_sent)
            dut.ddr_rd_data_valid.value = 1
            dut.ddr_rd_data_end.value = 1
            read_beats_sent += 1
        else:
            dut.ddr_rd_data_valid.value = 0
            dut.ddr_rd_data_end.value = 0

        if int(dut.cache_wr_en.value):
            writes[int(dut.cache_wr_addr.value)] = int(dut.cache_wr_data.value)

        if int(dut.done.value):
            break

    assert int(dut.done.value) == 1
    assert int(dut.error.value) == 0
    assert len(cmd_addrs) == 16
    assert cmd_addrs[0] == 0x1000
    assert cmd_addrs[-1] == 0x1000 + 15 * 32
    assert len(writes) == 512
    for addr in range(512):
        assert writes[addr] == (addr & 0xFF)

    cover("shared_ai.ddr_prefetch_commands")
    cover("shared_ai.ddr_prefetch_cache_fill")


@cocotb.test()
async def test_ddr3_weight_prefetcher_timeout_error(dut):
    """If DDR3 never returns read data, the prefetcher times out (16-bit wait_timer
    -> 0xFFFF) and raises `error` instead of hanging. The shared core FSM uses this
    to skip the channel rather than deadlock."""
    cocotb.start_soon(Clock(dut.sys_clk, 10, unit="ns").start())
    await reset(dut)

    dut.base_addr.value = 0x2000
    dut.ddr_cmd_ready.value = 1
    dut.ddr_rd_data_valid.value = 0   # never deliver data -> ST_WAIT watchdog trips
    dut.start.value = 1
    await RisingEdge(dut.sys_clk)
    dut.start.value = 0

    await Timer(700, unit="us")       # > 65535 cycles for the 16-bit timer
    assert int(dut.error.value) == 1, "prefetcher did not raise error on DDR timeout"
    assert int(dut.done.value) == 0, "prefetcher reported done despite no data"
    cover("shared_ai.ddr_prefetch_timeout")
