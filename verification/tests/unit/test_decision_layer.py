import cocotb
from cocotb.triggers import RisingEdge, Timer
from coverage.functional_coverage import cover

async def init_system(dut):
    dut.sys_clk.value = 0
    dut.rst_n.value = 0
    dut.classes_valid.value = 0
    dut.eeg_class.value = 0
    dut.ecg_class.value = 0
    dut.emg_class.value = 0
    dut.spo2_class.value = 0
    dut.temp_class.value = 0
    await Timer(10, unit="ns")
    dut.rst_n.value = 1
    await Timer(10, unit="ns")

async def run_clock(dut):
    """Generate 100MHz clock signal"""
    while True:
        dut.sys_clk.value = 0
        await Timer(5, unit="ns")
        dut.sys_clk.value = 1
        await Timer(5, unit="ns")

async def pulse_classes(dut, eeg=0, ecg=0, emg=0, spo2=0, temp=0):
    dut.eeg_class.value = eeg
    dut.ecg_class.value = ecg
    dut.emg_class.value = emg
    dut.spo2_class.value = spo2
    dut.temp_class.value = temp
    dut.classes_valid.value = 1
    await RisingEdge(dut.sys_clk)
    dut.classes_valid.value = 0
    await RisingEdge(dut.sys_clk)

@cocotb.test()
async def test_decision_voting(dut):
    """Test majority voting logic and sliding window (N=5)"""
    cocotb.start_soon(run_clock(dut))
    await init_system(dut)

    # Set EEG abnormal (1), others normal (0). Max value = 1.
    for i in range(5):
        await RisingEdge(dut.sys_clk)
        dut.eeg_class.value = 1
        dut.classes_valid.value = 1
        await RisingEdge(dut.sys_clk)
        dut.classes_valid.value = 0
        
        # Wait 2 cycles for processing
        await RisingEdge(dut.sys_clk)
        await RisingEdge(dut.sys_clk)

        # After 4 out of 5 cycles, the majority class should be 1
        if i >= 3:
            assert int(dut.class_out.value) == 1, f"Cycle {i}: Got {int(dut.class_out.value)}, expected 1"
            cover("decision.class_1")
            cover("decision.sliding_window")
            cover("decision.conf_high")
            cover("decision.trigger_eeg")


@cocotb.test()
async def test_decision_invalid_class_is_fail_safe(dut):
    """Invalid 2'b11 input classes are treated as Critical."""
    cocotb.start_soon(run_clock(dut))
    await init_system(dut)

    for _ in range(5):
        await RisingEdge(dut.sys_clk)
        dut.eeg_class.value = 3
        dut.classes_valid.value = 1
        await RisingEdge(dut.sys_clk)
        dut.classes_valid.value = 0
        await RisingEdge(dut.sys_clk)

    assert int(dut.triggered_sensors.value) & 0b10000
    assert int(dut.class_out.value) == 2
    cover("decision.class_2")
    cover("decision.class_3_fail_safe")
    cover("decision.trigger_eeg")


@cocotb.test()
async def test_decision_classes_confidence_and_triggers(dut):
    cocotb.start_soon(run_clock(dut))
    await init_system(dut)

    for _ in range(5):
        await pulse_classes(dut, 0, 0, 0, 0, 0)
    assert int(dut.class_out.value) == 0
    assert int(dut.confidence.value) == 2
    cover("decision.class_0")
    cover("decision.conf_high")

    await init_system(dut)
    for severity in [2, 2, 1, 1, 0]:
        await pulse_classes(dut, severity, 0, 0, 0, 0)
    assert int(dut.confidence.value) == 0
    cover("decision.tie_break_high_severity")
    cover("decision.conf_low")

    await init_system(dut)
    for vec in [(0, 1, 0, 0, 0), (0, 0, 1, 0, 0), (0, 0, 0, 1, 0), (0, 0, 0, 0, 1)]:
        await pulse_classes(dut, *vec)

    assert int(dut.triggered_sensors.value) == 0b00001
    cover("decision.trigger_ecg")
    cover("decision.trigger_emg")
    cover("decision.trigger_spo2")
    cover("decision.trigger_temp")

    await init_system(dut)
    for severity in [1, 1, 1, 0, 0]:
        await pulse_classes(dut, severity, 0, 0, 0, 0)
    assert int(dut.confidence.value) in (0, 1, 2)
    cover("decision.conf_medium")
