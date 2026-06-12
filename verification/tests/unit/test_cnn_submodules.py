import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge
from coverage.functional_coverage import cover


async def reset(dut):
    dut.rst_n.value = 0
    for name in [
        "dw_x_valid", "dw_frame_start", "pw_x_valid", "pw_frame_start",
        "mp_x_valid", "mp_frame_start", "gap_x_valid", "gap_frame_start",
        "fc_gap_valid",
    ]:
        getattr(dut, name).value = 0
    dut.relu_x.value = 0
    dut.dw_x_in.value = 0
    dut.dw_w.value = 0
    dut.dw_b.value = 0
    dut.pw_x_in.value = 0
    dut.pw_w.value = 0
    dut.pw_b.value = 0
    dut.mp_x_in.value = 0
    dut.gap_x_in.value = 0
    dut.fc_gap_in.value = 0
    dut.fc_w.value = 0
    dut.fc_b.value = 0
    for _ in range(6):
        await RisingEdge(dut.sys_clk)
    dut.rst_n.value = 1
    for _ in range(4):
        await RisingEdge(dut.sys_clk)


def pack_int8(values):
    out = 0
    for idx, value in enumerate(values):
        out |= (value & 0xFF) << (idx * 8)
    return out


def pack_int16(values):
    out = 0
    for idx, value in enumerate(values):
        out |= (value & 0xFFFF) << (idx * 16)
    return out


def pack_int32(values):
    out = 0
    for idx, value in enumerate(values):
        out |= (value & 0xFFFFFFFF) << (idx * 32)
    return out


@cocotb.test()
async def test_cnn_submodule_smoke(dut):
    cocotb.start_soon(Clock(dut.sys_clk, 10, unit="ns").start())
    await reset(dut)

    dut.relu_x.value = (-5) & 0xFFFF
    await RisingEdge(dut.sys_clk)
    assert int(dut.relu_y.value) == 0
    dut.relu_x.value = 200
    await RisingEdge(dut.sys_clk)
    assert int(dut.relu_y.value) == 127
    dut.relu_x.value = 42
    await RisingEdge(dut.sys_clk)
    assert int(dut.relu_y.value) == 42
    cover("cnn_sub.relu_clip")

    dut.dw_w.value = pack_int8([0, 0, 0, 0, 1, 0, 0, 0, 0])
    dut.dw_b.value = 0
    dut.dw_frame_start.value = 1
    await RisingEdge(dut.sys_clk)
    dut.dw_frame_start.value = 0
    for sample in [1, 2, 3, 4]:
        dut.dw_x_in.value = sample
        dut.dw_x_valid.value = 1
        await RisingEdge(dut.sys_clk)
    dut.dw_x_valid.value = 0
    for _ in range(16):
        await RisingEdge(dut.sys_clk)
        if int(dut.dw_y_valid.value):
            cover("cnn_sub.conv_dw")
            break
    else:
        raise AssertionError("Depthwise conv did not emit y_valid")

    dut.pw_w.value = pack_int8([1, 0, 0, 1])
    dut.pw_b.value = pack_int32([0, 0])
    dut.pw_frame_start.value = 1
    await RisingEdge(dut.sys_clk)
    dut.pw_frame_start.value = 0
    dut.pw_x_in.value = pack_int16([5, 9])
    dut.pw_x_valid.value = 1
    await RisingEdge(dut.sys_clk)
    dut.pw_x_valid.value = 0
    # Phase 5b: 5-stage PW pipeline (capture → mult → partial → final → shift).
    # Output appears within ~6 cycles of the x_valid pulse. Loop limit is a
    # ceiling, not a loosened assertion — we still strictly require pw_y_valid==1
    # and pw_y_out to match the expected value below.
    for _ in range(8):
        await RisingEdge(dut.sys_clk)
        if int(dut.pw_y_valid.value):
            break
    assert int(dut.pw_y_valid.value) == 1
    assert int(dut.pw_y_out.value) == pack_int16([5, 9])
    cover("cnn_sub.conv_pw")

    dut.mp_frame_start.value = 1
    await RisingEdge(dut.sys_clk)
    dut.mp_frame_start.value = 0
    for sample in [1, 3, 2, 7]:
        dut.mp_x_in.value = sample
        dut.mp_x_valid.value = 1
        await RisingEdge(dut.sys_clk)
    dut.mp_x_valid.value = 0
    # Phase 5c: maxpool compare split into 2 stages (pairwise → final), so
    # y_valid arrives 1-2 cycles later than the Phase 5b single-cycle design.
    # The loop is a watchdog ceiling — the assertions on mp_y_valid==1 and
    # mp_y_out==7 below remain strict.
    for _ in range(8):
        await RisingEdge(dut.sys_clk)
        if int(dut.mp_y_valid.value):
            break
    assert int(dut.mp_y_valid.value) == 1
    assert int(dut.mp_y_out.value) == 7
    cover("cnn_sub.maxpool")

    dut.gap_frame_start.value = 1
    await RisingEdge(dut.sys_clk)
    dut.gap_frame_start.value = 0
    for sample in [1, 9, 3, 4]:
        dut.gap_x_in.value = sample
        dut.gap_x_valid.value = 1
        await RisingEdge(dut.sys_clk)
    dut.gap_x_valid.value = 0
    await RisingEdge(dut.sys_clk)
    assert int(dut.gap_valid.value) == 1
    assert int(dut.gap_out.value) == 9
    cover("cnn_sub.global_maxpool")

    dut.fc_w.value = pack_int8([1, 1, 2, 1, 1, 5])
    dut.fc_b.value = pack_int32([0, 0, 0])
    dut.fc_gap_in.value = pack_int16([1, 2])
    dut.fc_gap_valid.value = 1
    await RisingEdge(dut.sys_clk)
    dut.fc_gap_valid.value = 0
    # fc_layer is now 2 cycles/tap (ST_FETCH registers operands before the MAC) for
    # 16 inputs + serial argmax, so allow plenty of cycles for logits_valid.
    for _ in range(80):
        await RisingEdge(dut.sys_clk)
        if int(dut.fc_logits_valid.value):
            assert int(dut.fc_class_out.value) == 2
            cover("cnn_sub.fc_argmax")
            break
    else:
        raise AssertionError("FC layer did not emit logits_valid")
