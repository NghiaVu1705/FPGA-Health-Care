"""Real-top integration test for ``top_shared_ai``.

Unlike ``test_shared_ai_full_pipeline`` (which wires ``biomed_shared_ai_system``
into a hand-written harness), this test elaborates the ACTUAL ``top_shared_ai``
module and exercises its on-chip boot path end to end:

    weight_image_rom -> boot FSM -> weight_boot_loader (CRC) -> DDR3 (behavioural
    gowin_ip_models memory) -> biomed_shared_ai_system DDR prefetch.

It closes the previously-untested gaps:
  * the real top boot FSM (BOOT_RESET -> LOAD_WEIGHTS -> WAIT_CALIB -> RUN),
  * the registered ``weight_image_rom`` + 1-cycle ``pending`` streaming bubble
    (the manifest CRC inside weight_boot_loader is the byte-alignment oracle:
    any off-by-one fails CRC and raises weight_load_error),
  * the DDR write/read port MUX (``ddr_boot_owns_port``),
  * the AI core actually reading the boot-loaded weights from DDR after release.

CNN class correctness is already proven bit-exact by cnn_parity / the
full-pipeline test against the same weights and DDR contents, so it is not
re-checked here.
"""

from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from coverage.functional_coverage import cover

PROJECT_ROOT = Path(__file__).resolve().parents[3]
EEG_WEIGHTS = PROJECT_ROOT / "rtl/gowin_bsram/eeg/cnn_weights.hex"
ECG_WEIGHTS = PROJECT_ROOT / "rtl/gowin_bsram/ecg/cnn_weights.hex"
EMG_WEIGHTS = PROJECT_ROOT / "rtl/gowin_bsram/emg/cnn_weights.hex"
WEIGHT_BASE = {0: 0, 1: 4096, 2: 8192}


def _read_weight_hex(path: Path) -> list[int]:
    return [int(line.strip(), 16) & 0xFF for line in path.read_text().splitlines() if line.strip()]


async def _idle_inputs(dut):
    dut.rst_n.value = 0
    dut.case_next_n.value = 1      # released (no replay), boot path only
    dut.uart_rx_emg.value = 1
    dut.spi_sck.value = 0
    dut.spi_mosi.value = 0
    dut.spi_cs_n.value = 1
    dut.i2c_scl.value = 1


@cocotb.test()
async def test_real_top_boot_loads_ddr_and_releases_ai(dut):
    """Boot weights into DDR through the real top, then confirm AI prefetch reads them."""

    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await _idle_inputs(dut)
    for _ in range(20):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1

    # ── Boot: wait for the on-chip loader to finish streaming the ROM to DDR ──
    done = False
    for _ in range(60000):
        await RisingEdge(dut.clk)
        if dut.weight_load_done.value.is_resolvable and int(dut.weight_load_done.value):
            done = True
            break
        if dut.weight_load_error.value.is_resolvable and int(dut.weight_load_error.value):
            break

    assert done, "real top boot FSM never asserted weight_load_done"
    assert int(dut.weight_load_error.value) == 0, (
        "weight_load_error set -> CRC/alignment failure in the registered "
        "weight_image_rom streaming path"
    )
    cover("system.real_top_weight_boot")

    # ── DDR payload correctness: per-channel weight image landed at its base ──
    for channel, path in ((0, EEG_WEIGHTS), (1, ECG_WEIGHTS), (2, EMG_WEIGHTS)):
        expected = _read_weight_hex(path)[:32]
        base = WEIGHT_BASE[channel]
        observed = [int(dut.u_ddr3.mem[base + i].value) for i in range(32)]
        assert observed == expected, (
            f"DDR payload mismatch for channel {channel} at base {base}: "
            f"{observed[:8]} != {expected[:8]}"
        )
    cover("system.real_top_ddr_payload")

    # ── AI release: the core leaves reset and prefetches a channel's weights ──
    prefetched = False
    for _ in range(40000):
        await RisingEdge(dut.clk)
        wr = dut.u_shared_ai.weights_ready
        if wr.value.is_resolvable and int(wr.value):
            prefetched = True
            break
    assert prefetched, "AI core never reported weights_ready after boot (DDR prefetch stalled)"
    assert dut.u_shared_ai.active_channel.value.is_resolvable
    cover("system.real_top_ai_prefetch")

    # ── Display alive: TMDS outputs resolvable ──
    assert dut.tmds_clk_p_0.value.is_resolvable
    assert dut.tmds_d_p_0.value.is_resolvable
    cover("system.real_top_tmds")


async def _bring_up(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await _idle_inputs(dut)
    for _ in range(20):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    for _ in range(10):
        await RisingEdge(dut.clk)


@cocotb.test()
async def test_replay_case_window_and_vitals(dut):
    """Multi-case replay: replay_case selects the ROM window + per-case vitals.

    White-box: deposit replay_case (live=0, 1=Normal, 2=Abnormal, 3=Critical) and
    check window-base addressing (rep_win, rep_rom_addr={rep_win,rep_addr}) and the
    simulated vitals MUX. Keep in sync with the CASES vitals in top_shared_ai.v /
    extract_sample.py.
    """
    await _bring_up(dut)

    # case -> (rep_win, spo2, temp)
    cases = {1: (0, 98, 72), 2: (1, 92, 72), 3: (2, 88, 80)}
    for case, (win, spo2, temp) in cases.items():
        dut.replay_case.value = case      # deposit (button not pressed -> holds)
        await Timer(1, unit="ns")
        assert int(dut.mode_replay.value) == 1, f"case {case}: mode_replay off"
        assert int(dut.rep_win.value) == win, f"case {case}: rep_win {int(dut.rep_win.value)} != {win}"
        # rep_rom_addr = {rep_win, rep_addr}: upper bits = window base, lower = idx.
        addr = int(dut.rep_rom_addr.value)
        assert (addr >> 11) == win, f"case {case}: rom_addr window base {addr >> 11} != {win}"
        assert (addr & 0x7FF) == int(dut.rep_addr.value), f"case {case}: rom_addr sample idx mismatch"
        assert int(dut.spo2_disp.value) == spo2, f"case {case}: spo2 {int(dut.spo2_disp.value)} != {spo2}"
        assert int(dut.temp_disp.value) == temp, f"case {case}: temp {int(dut.temp_disp.value)} != {temp}"
        cover("replay.case_window", case=case, win=win)
        cover("replay.case_vitals", case=case, spo2=spo2, temp=temp)

    # live (case 0): replay off, vitals pass through from the (idle) I2C defaults.
    dut.replay_case.value = 0
    await Timer(1, unit="ns")
    assert int(dut.mode_replay.value) == 0, "live: mode_replay should be off"
    assert int(dut.spo2_disp.value) == int(dut.spo2_raw.value), "live: spo2 not pass-through"
    assert int(dut.temp_disp.value) == int(dut.temp_raw.value), "live: temp not pass-through"
    cover("replay.live_passthrough")


@cocotb.test()
async def test_replay_button_advances_case(dut):
    """One AB13 press (debounced) advances replay_case 0->1 and asserts mode_replay."""
    await _bring_up(dut)
    assert int(dut.replay_case.value) == 0, "replay_case should start at live (0)"
    assert int(dut.mode_replay.value) == 0

    # Hold case_next_n low past the 16-bit debounce (65535 cycles). One Timer
    # advances ~70k cycles without 70k Python awaits.
    dut.case_next_n.value = 0
    await Timer(700, unit="us")
    assert int(dut.replay_case.value) == 1, "debounced press did not advance replay_case"
    assert int(dut.mode_replay.value) == 1, "press did not enter replay mode"
    cover("replay.button_press")


@cocotb.test()
async def test_boot_error_then_replay_bypass(dut):
    """Corrupt the weight image header -> boot raises weight_load_error and never
    reaches RUN; the replay bypass (run_enable_eff = boot_run_enable | mode_replay)
    still releases the AI core so the self-test demo survives a dead/failed boot."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await _idle_inputs(dut)
    dut.rst_n.value = 0

    # Corrupt the first magic byte ("BMEDWGT1") so weight_boot_loader rejects it.
    orig = int(dut.u_weight_image_rom.mem[0].value)
    dut.u_weight_image_rom.mem[0].value = orig ^ 0xFF
    for _ in range(20):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1

    err = False
    for _ in range(80000):
        await RisingEdge(dut.clk)
        if dut.weight_load_error.value.is_resolvable and int(dut.weight_load_error.value):
            err = True
            break
        if int(dut.weight_load_done.value):
            break
    assert err, "corrupt weight image did not raise weight_load_error"
    assert int(dut.weight_load_done.value) == 0, "boot reported done on a corrupt image"
    assert int(dut.boot_run_enable.value) == 0, "boot reached RUN despite the error"
    cover("system.boot_error")

    # Replay bypass: entering a replay case releases the AI core anyway.
    dut.replay_case.value = 1
    await Timer(1, unit="ns")
    assert int(dut.mode_replay.value) == 1
    assert int(dut.run_enable_eff.value) == 1, "replay bypass did not release the AI core"
    cover("system.replay_bypass_on_boot_error")

    dut.u_weight_image_rom.mem[0].value = orig   # restore for any later run
