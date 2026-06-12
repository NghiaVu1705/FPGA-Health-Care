from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

from coverage.functional_coverage import cover


PROJECT_ROOT = Path(__file__).resolve().parents[3]
WEIGHT_IMAGE = PROJECT_ROOT / "artifacts/weights/biomed_weights.bin"
WEIGHT_HEX = {
    0: PROJECT_ROOT / "rtl/gowin_bsram/eeg/cnn_weights.hex",
    1: PROJECT_ROOT / "rtl/gowin_bsram/ecg/cnn_weights.hex",
    2: PROJECT_ROOT / "rtl/gowin_bsram/emg/cnn_weights.hex",
}
WEIGHT_BASE = {0: 0, 1: 4096, 2: 8192}
REPLAY_HEX = {
    0: PROJECT_ROOT / "rtl/top/test_eeg.hex",
    1: PROJECT_ROOT / "rtl/top/test_ecg.hex",
    2: PROJECT_ROOT / "rtl/top/test_emg.hex",
}
# The replay hex now concatenates N case windows (extract_sample.py CASES).
# Drive the CRITICAL case (window index 2) so every channel + vitals escalate.
REPLAY_WINDOW = 2
EXPECTED_CLASS = {
    0: 2,  # EEG: Tonic-Clonic Seizure -> Critical
    1: 4,  # ECG: Myocardial Ischemia  -> Critical
    2: 3,  # EMG: ALS                  -> Critical
}


def _read_i16_hex(path: Path, window: int = 0) -> list[int]:
    values = []
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line:
            continue
        word = int(line, 16) & 0xFFFF
        values.append(word - 0x10000 if word & 0x8000 else word)
    assert len(values) % 2048 == 0 and len(values) >= 2048 * (window + 1), (
        f"{path} has {len(values)} samples (need window {window})"
    )
    return values[window * 2048:(window + 1) * 2048]


def _read_weight_hex(path: Path) -> list[int]:
    values = [int(line.strip(), 16) & 0xFF for line in path.read_text().splitlines() if line.strip()]
    return values + [0] * (512 - len(values))


async def _reset(dut):
    dut.rst_n.value = 0
    dut.boot_start.value = 0
    dut.flash_data.value = 0
    dut.flash_valid.value = 0
    dut.eeg_sample.value = 0
    dut.eeg_valid.value = 0
    dut.ecg_sample.value = 0
    dut.ecg_valid.value = 0
    dut.emg_sample.value = 0
    dut.emg_valid.value = 0
    dut.spo2_raw.value = 94
    dut.temp_raw.value = 74
    dut.vitals_updated.value = 0
    for _ in range(8):
        await RisingEdge(dut.sys_clk)
    dut.rst_n.value = 1
    for _ in range(4):
        await RisingEdge(dut.sys_clk)


async def _boot_weights(dut):
    image = WEIGHT_IMAGE.read_bytes()

    dut.boot_start.value = 1
    await RisingEdge(dut.sys_clk)
    dut.boot_start.value = 0

    idx = 0
    dut.flash_data.value = image[0]
    dut.flash_valid.value = 1
    while idx < len(image):
        await RisingEdge(dut.sys_clk)
        if int(dut.flash_ready.value):
            idx += 1
            if idx < len(image):
                dut.flash_data.value = image[idx]
            else:
                dut.flash_valid.value = 0

    for _ in range(20000):
        await RisingEdge(dut.sys_clk)
        if int(dut.weight_load_done.value) or int(dut.weight_load_error.value):
            break
    assert int(dut.weight_load_error.value) == 0, "weight boot loader reported CRC/load error"
    assert int(dut.weight_load_done.value) == 1, "weight boot loader did not finish"
    assert int(dut.ddr_write_seen.value) == 1, "weight boot did not write DDR"
    assert int(dut.boot_write_count.value) >= 58, "weight boot emitted too few DDR write beats"
    for channel, path in WEIGHT_HEX.items():
        expected = _read_weight_hex(path)
        base = WEIGHT_BASE[channel]
        observed = [int(dut.ddr_mem[base + idx].value) for idx in range(32)]
        assert observed == expected[:32], f"DDR payload mismatch at channel {channel} base {base}"
    cover("system.weight_boot_to_ddr")


async def _wait_for_channel_ready(dut, channel: int):
    for _ in range(5000):
        await RisingEdge(dut.sys_clk)
        if (
            dut.active_channel.value.is_resolvable
            and int(dut.active_channel.value) == channel
            and int(dut.weights_ready.value) == 1
        ):
            return
    raise AssertionError(f"channel {channel} did not finish DDR weight prefetch")


async def _feed_channel_samples(dut, channel: int, samples: list[int]):
    ready_name = ["eeg_ready", "ecg_ready", "emg_ready"][channel]
    valid_name = ["eeg_valid", "ecg_valid", "emg_valid"][channel]
    sample_name = ["eeg_sample", "ecg_sample", "emg_sample"][channel]
    ready = getattr(dut, ready_name)
    valid = getattr(dut, valid_name)
    sample = getattr(dut, sample_name)

    sent = 0
    while sent < len(samples):
        await RisingEdge(dut.sys_clk)
        if int(ready.value):
            sample.value = samples[sent] & 0xFFFF
            valid.value = 1
            sent += 1
        else:
            valid.value = 0

    await RisingEdge(dut.sys_clk)
    valid.value = 0


async def _wait_for_cnn_class(dut, channel: int) -> int:
    for _ in range(260000):
        await RisingEdge(dut.sys_clk)
        class_valid = dut.u_shared_ai.u_shared_cnn.class_valid.value
        if class_valid.is_resolvable and int(class_valid):
            assert int(dut.active_channel.value) == channel
            return int(dut.u_shared_ai.u_shared_cnn.class_out.value)
    raise AssertionError(f"channel {channel} did not produce a CNN class")


@cocotb.test()
async def test_weight_boot_to_ddr_then_replay_stft_cnn_decision_osd(dut):
    """Full path: boot weights into DDR, then replay EEG/ECG/EMG through real AI."""

    replay = {channel: _read_i16_hex(path, REPLAY_WINDOW) for channel, path in REPLAY_HEX.items()}

    cocotb.start_soon(Clock(dut.sys_clk, 10, unit="ns").start())
    await _reset(dut)
    await _boot_weights(dut)

    observed = {}
    for channel in (0, 1, 2):
        await _wait_for_channel_ready(dut, channel)
        assert int(dut.ddr_read_seen.value) == 1, "AI prefetch did not read DDR"
        cover("system.ddr_weights_used", channel=channel)

        await _feed_channel_samples(dut, channel, replay[channel])
        observed[channel] = await _wait_for_cnn_class(dut, channel)
        assert observed[channel] == EXPECTED_CLASS[channel], (
            f"channel {channel} class mismatch: "
            f"expected {EXPECTED_CLASS[channel]}, observed {observed[channel]}"
        )
        cover("system.replay_expected_class", channel=channel, observed=observed[channel])

    for _ in range(20):
        await RisingEdge(dut.sys_clk)

    assert int(dut.final_class.value) == 2, "decision layer did not escalate to critical"
    assert (int(dut.triggered_sensors.value) & 0b11100) == 0b11100
    assert dut.osd_r.value.is_resolvable
    assert dut.osd_g.value.is_resolvable
    assert dut.osd_b.value.is_resolvable
    cover("system.decision_to_osd", final_class=int(dut.final_class.value))
