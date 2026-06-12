import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge
from coverage.functional_coverage import cover


async def reset(dut):
    dut.rst_n.value = 0
    dut.eeg_sample.value = 0
    dut.ecg_sample.value = 0
    dut.emg_sample.value = 0
    dut.eeg_valid.value = 0
    dut.ecg_valid.value = 0
    dut.emg_valid.value = 0
    dut.spo2_raw.value = 98
    dut.temp_raw.value = 72
    dut.vitals_valid.value = 0
    for _ in range(8):
        await RisingEdge(dut.sys_clk)
    dut.rst_n.value = 1
    for _ in range(8):
        await RisingEdge(dut.sys_clk)


@cocotb.test()
async def test_asic_wrapper_smoke(dut):
    cocotb.start_soon(Clock(dut.sys_clk, 10, unit="ns").start())
    await reset(dut)

    for _ in range(4):
        await RisingEdge(dut.sys_clk)
    assert dut.u_hamming_sram_eeg.Q.value.is_resolvable
    cover("asic.sram_read")

    dut.eeg_sample.value = 100
    dut.ecg_sample.value = (-100) & 0xFFFF
    dut.emg_sample.value = 55
    dut.eeg_valid.value = 1
    dut.ecg_valid.value = 1
    dut.emg_valid.value = 1
    await RisingEdge(dut.sys_clk)
    dut.eeg_valid.value = 0
    dut.ecg_valid.value = 0
    dut.emg_valid.value = 0
    cover("asic.three_channel_sample_input")

    for _ in range(5):
        dut.spo2_raw.value = 85
        dut.temp_raw.value = 80
        dut.vitals_valid.value = 1
        await RisingEdge(dut.sys_clk)
        dut.vitals_valid.value = 0
        await RisingEdge(dut.sys_clk)
    assert int(dut.final_class.value) == 2
    cover("asic.threshold_decision")
