from pathlib import Path

import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge
from coverage.functional_coverage import cover


PROJECT_ROOT = Path(__file__).resolve().parents[3]
WEIGHTS_HEX = PROJECT_ROOT / "rtl/gowin_bsram/eeg/cnn_weights.hex"
ECG_WEIGHTS_HEX = PROJECT_ROOT / "rtl/gowin_bsram/ecg/cnn_weights.hex"
EMG_WEIGHTS_HEX = PROJECT_ROOT / "rtl/gowin_bsram/emg/cnn_weights.hex"


def _read_bytes(path):
    data = [int(line.strip(), 16) for line in path.read_text().splitlines() if line.strip()]
    return data + [0] * (512 - len(data))


def _int8(value):
    value &= 0xFF
    return value - 256 if value >= 128 else value


def _int32_le(data):
    value = 0
    for idx, byte in enumerate(data):
        value |= (byte & 0xFF) << (8 * idx)
    return value - (1 << 32) if value & (1 << 31) else value


def _clip127(value):
    if value > 127:
        return 127
    if value < -127:
        return -127
    return int(value)


def _relu127(x):
    return np.clip(x, 0, 127).astype(np.int32)


def _conv_dw(x, weights, bias, shift):
    h, w, channels = x.shape
    out = np.zeros((h, w, channels), dtype=np.int32)
    for row in range(h):
        for col in range(w):
            for ch in range(channels):
                acc = int(bias[ch])
                for kr in range(3):
                    for kc in range(3):
                        rr = row + kr - 1
                        cc = col + kc - 1
                        if 0 <= rr < h and 0 <= cc < w:
                            acc += int(weights[ch, kr, kc]) * int(x[rr, cc, ch])
                out[row, col, ch] = _clip127(acc >> shift)
    return out


def _conv_pw(x, weights, bias, shift):
    h, w, channels = x.shape
    out_channels = weights.shape[0]
    out = np.zeros((h, w, out_channels), dtype=np.int32)
    for row in range(h):
        for col in range(w):
            for co in range(out_channels):
                acc = int(bias[co])
                for ci in range(channels):
                    acc += int(weights[co, ci]) * int(x[row, col, ci])
                out[row, col, co] = _clip127(acc >> shift)
    return out


def _maxpool2x2(x):
    h, w, channels = x.shape
    return x.reshape(h // 2, 2, w // 2, 2, channels).max(axis=(1, 3)).astype(np.int32)


def _decode_weights(mem):
    signed = np.array([_int8(byte) for byte in mem], dtype=np.int32)
    biases = [_int32_le(mem[idx : idx + 4]) for idx in range(272, 416, 4)]
    return {
        "dw1_w": signed[0:9].reshape(1, 3, 3),
        "pw1_w": signed[16:24].reshape(8, 1),
        "dw2_w": signed[24:96].reshape(8, 3, 3),
        "pw2_w": signed[96:224].reshape(16, 8),
        "fc_w": signed[224:272].reshape(3, 16),
        "dw1_b": np.array([biases[0]], dtype=np.int32),
        "pw1_b": np.array(biases[1:9], dtype=np.int32),
        "dw2_b": np.array(biases[9:17], dtype=np.int32),
        "pw2_b": np.array(biases[17:33], dtype=np.int32),
        "fc_b": np.array(biases[33:36], dtype=np.int32),
        "shift_dw1": mem[416] & 0x1F,
        "shift_pw1": mem[417] & 0x1F,
        "shift_dw2": mem[418] & 0x1F,
        "shift_pw2": mem[419] & 0x1F,
        "shift_fc": mem[420] & 0x1F,
    }


def _tiny_cnn_model(spec, params):
    x = spec.astype(np.int32).reshape(32, 32, 1)
    x = _relu127(_conv_dw(x, params["dw1_w"], params["dw1_b"], params["shift_dw1"]))
    x = _relu127(_conv_pw(x, params["pw1_w"], params["pw1_b"], params["shift_pw1"]))
    x = _maxpool2x2(x)
    x = _relu127(_conv_dw(x, params["dw2_w"], params["dw2_b"], params["shift_dw2"]))
    x = _relu127(_conv_pw(x, params["pw2_w"], params["pw2_b"], params["shift_pw2"]))
    x = _maxpool2x2(x)
    gap = x.max(axis=(0, 1))

    logits = []
    for co in range(3):
        acc = int(params["fc_b"][co])
        for ci in range(16):
            acc += int(params["fc_w"][co, ci]) * int(gap[ci])
        logits.append(_clip127(acc >> params["shift_fc"]))
    return int(np.argmax(np.array(logits, dtype=np.int32))), logits


def _spectrogram_fixture():
    yy, xx = np.mgrid[0:32, 0:32]
    ridge = 70.0 * np.exp(-((xx - 9.0) ** 2) / 18.0)
    rhythm = 22.0 * (1.0 + np.sin(2.0 * np.pi * yy / 8.0))
    gradient = (xx * 3 + yy * 2) % 19
    return np.clip(10.0 + ridge + rhythm + gradient, 0, 127).astype(np.uint8)


async def _reset(dut):
    dut.rst_n.value = 0
    dut.spec_in.value = 0
    dut.spec_valid.value = 0
    dut.spec_start.value = 0
    dut.bsram_data.value = 0
    for _ in range(8):
        await RisingEdge(dut.sys_clk)
    dut.rst_n.value = 1
    for _ in range(4):
        await RisingEdge(dut.sys_clk)


async def _drive_weight_rom(dut, mem):
    dut.bsram_data.value = 0
    while True:
        await RisingEdge(dut.sys_clk)
        addr = dut.bsram_addr.value
        if addr.is_resolvable:
            dut.bsram_data.value = mem[int(addr) & 0x1FF]
        else:
            dut.bsram_data.value = 0



@cocotb.test()
async def test_cnn_top_classification_matches_numpy_model(dut):
    """Load the EEG weight ROM image and compare final class to numpy Tiny CNN."""

    mem = _read_bytes(WEIGHTS_HEX)
    assert len(_read_bytes(ECG_WEIGHTS_HEX)) >= 512
    assert len(_read_bytes(EMG_WEIGHTS_HEX)) >= 512
    cover("cnn.rom_eeg")
    cover("cnn.rom_ecg")
    cover("cnn.rom_emg")

    params = _decode_weights(mem)
    spec = _spectrogram_fixture()
    expected_class, expected_logits = _tiny_cnn_model(spec, params)

    cocotb.start_soon(Clock(dut.sys_clk, 10, unit="ns").start())
    cocotb.start_soon(_drive_weight_rom(dut, mem))
    await _reset(dut)

    for _ in range(440):
        await RisingEdge(dut.sys_clk)

    flat_spec = spec.reshape(-1)
    for idx, value in enumerate(flat_spec):
        dut.spec_in.value = int(value)
        dut.spec_valid.value = 1
        dut.spec_start.value = 1 if idx == 0 else 0
        await RisingEdge(dut.sys_clk)
        if idx == 0:
            cover("cnn.first_byte_start")
        if idx == 17:
            dut.spec_valid.value = 0
            await RisingEdge(dut.sys_clk)
            dut.spec_valid.value = 1
            cover("cnn.valid_gap")

    dut.spec_valid.value = 0
    dut.spec_start.value = 0

    observed_class = None
    for _ in range(12000):
        await RisingEdge(dut.sys_clk)
        if int(dut.class_valid.value):
            observed_class = int(dut.class_out.value)
            break

    dut._log.info("Expected logits from numpy model: %s", expected_logits)
    assert observed_class is not None, "Timed out waiting for cnn_top class_valid"
    assert observed_class == expected_class
    cover("cnn.numpy_match", expected_class=expected_class)
