import random
import cocotb
from cocotb.triggers import Timer
from coverage.functional_coverage import cover

def threshold_golden_model(spo2, temp):
    # SpO2 Class
    if spo2 < 90:
        spo2_class = 2  # Critical
    elif spo2 < 95:
        spo2_class = 1  # Abnormal
    else:
        spo2_class = 0  # Normal

    # Temp Class: 0.5°C/LSB (72 = 36.0°C)
    # TEMP_CRITICAL_H = 78 (39°C), TEMP_CRITICAL_L = 70 (35°C)
    # TEMP_ABNORMAL_H = 75 (37.5°C), TEMP_ABNORMAL_L = 72 (36°C)
    if temp > 78 or temp < 70:
        temp_class = 2  # Critical
    elif temp > 75 or temp < 72:
        temp_class = 1  # Abnormal
    else:
        temp_class = 0  # Normal

    return spo2_class, temp_class

@cocotb.test()
async def test_threshold_boundary_and_random(dut):
    """Test boundary and random inputs for threshold_proc"""
    
    # Boundary test cases (spo2, temp)
    test_cases = [
        (89, 74), (90, 74), (94, 74), (95, 74),  # SpO2 boundaries
        (98, 69), (98, 70), (98, 71), (98, 72),  # Temp lower boundaries
        (98, 74), (98, 75), (98, 76), (98, 78),  # Temp upper boundaries
        (98, 79)
    ]

    for spo2_raw, temp_raw in test_cases:
        dut.spo2_raw.value = spo2_raw
        dut.temp_raw.value = temp_raw
        await Timer(2, unit="ns")

        exp_spo2, exp_temp = threshold_golden_model(spo2_raw, temp_raw)
        
        assert int(dut.spo2_class.value) == exp_spo2, f"SpO2 Fail: Raw={spo2_raw}, Got={int(dut.spo2_class.value)}, Exp={exp_spo2}"
        assert int(dut.temp_class.value) == exp_temp, f"Temp Fail: Raw={temp_raw}, Got={int(dut.temp_class.value)}, Exp={exp_temp}"
        if exp_spo2 == 0:
            cover("threshold.spo2_normal", value=spo2_raw)
        elif exp_spo2 == 1:
            cover("threshold.spo2_abnormal", value=spo2_raw)
        else:
            cover("threshold.spo2_critical", value=spo2_raw)

        if exp_temp == 0:
            cover("threshold.temp_normal", value=temp_raw)
        elif exp_temp == 1 and temp_raw < 72:
            cover("threshold.temp_abnormal_low", value=temp_raw)
        elif exp_temp == 1:
            cover("threshold.temp_abnormal_high", value=temp_raw)
        elif temp_raw < 70:
            cover("threshold.temp_critical_low", value=temp_raw)
        else:
            cover("threshold.temp_critical_high", value=temp_raw)

    # Random test cases
    random.seed(42)
    for _ in range(100):
        spo2_raw = random.randint(0, 100)
        temp_raw = random.randint(50, 100)
        dut.spo2_raw.value = spo2_raw
        dut.temp_raw.value = temp_raw
        await Timer(2, unit="ns")
        
        exp_spo2, exp_temp = threshold_golden_model(spo2_raw, temp_raw)
        assert int(dut.spo2_class.value) == exp_spo2
        assert int(dut.temp_class.value) == exp_temp

    cover("threshold.random_constrained", samples=100)
