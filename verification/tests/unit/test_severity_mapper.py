"""Exhaustive 6-class -> 3-level severity-mapper coverage (biomed_shared_ai_system).

The shared core folds each modality's 6 CNN diagnosis classes into 3 standardized
severity levels (0=Normal, 1=Abnormal, 2=Critical) via the ``*_severity_map``
functions before decision_layer. Those functions had NO direct test (only the
Critical combo was implied by the full-pipeline test). Here we drive every class
0..5 per modality and check the severity wire that feeds decision_layer.

Method: hold the core idle (no spectrogram -> cnn_class_valid stays 0, so
``*_class_dec = *_class_r``), deposit ``*_class_r``, and read the combinational
``*_severity``. Tables mirror Spec 3.5b / the EEG/ECG/EMG_CRITICAL_CLASS params.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from coverage.functional_coverage import cover

# class -> severity. Critical class: EEG 2 (Tonic-Clonic), ECG 4 (Ischemia),
# EMG 3 (ALS). Class 0 -> Normal. Everything else -> Abnormal.
EEG_SEV = {0: 0, 1: 1, 2: 2, 3: 1, 4: 1, 5: 1}
ECG_SEV = {0: 0, 1: 1, 2: 1, 3: 1, 4: 2, 5: 1}
EMG_SEV = {0: 0, 1: 1, 2: 1, 3: 2, 4: 1, 5: 1}


async def _reset(dut):
    dut.rst_n.value = 0
    for s in ("eeg_sample", "eeg_valid", "ecg_sample", "ecg_valid",
              "emg_sample", "emg_valid", "vitals_updated",
              "ddr_rd_data_valid", "ddr_rd_data_end", "ddr_rd_data",
              "hamming_rom_data", "twiddle_rom_data"):
        getattr(dut, s).value = 0
    dut.spo2_raw.value = 98
    dut.temp_raw.value = 72
    dut.ddr_cmd_ready.value = 1
    for _ in range(8):
        await RisingEdge(dut.sys_clk)
    dut.rst_n.value = 1
    for _ in range(4):
        await RisingEdge(dut.sys_clk)


@cocotb.test()
async def test_severity_mapper_all_classes(dut):
    """All 18 mappings (3 modalities x 6 classes) -> 3 severity levels."""
    cocotb.start_soon(Clock(dut.sys_clk, 10, unit="ns").start())
    await _reset(dut)

    for c in range(6):
        # cnn_class_valid is 0 (no spectrogram fed) so *_class_dec == *_class_r.
        dut.eeg_class_r.value = c
        dut.ecg_class_r.value = c
        dut.emg_class_r.value = c
        await Timer(1, unit="ns")  # settle the combinational severity wires

        eeg = int(dut.eeg_severity.value)
        ecg = int(dut.ecg_severity.value)
        emg = int(dut.emg_severity.value)
        assert eeg == EEG_SEV[c], f"EEG class {c}: severity {eeg} != {EEG_SEV[c]}"
        assert ecg == ECG_SEV[c], f"ECG class {c}: severity {ecg} != {ECG_SEV[c]}"
        assert emg == EMG_SEV[c], f"EMG class {c}: severity {emg} != {EMG_SEV[c]}"
        cover("severity.eeg_map", cls=c, sev=eeg)
        cover("severity.ecg_map", cls=c, sev=ecg)
        cover("severity.emg_map", cls=c, sev=emg)

    # Spot-check the three severity levels are each reachable.
    for lvl, names in ((0, "normal"), (1, "abnormal"), (2, "critical")):
        cover("severity.level_reached", level=lvl, name=names)
