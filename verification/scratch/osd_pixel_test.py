#!/usr/bin/env python3
"""OSD pixel-level test (Icarus Verilog).

Streams test pixels through the REAL osd_overlay + text_renderer pipeline and
checks r/g/b at chosen coordinates/health-states. Used to lock the timing-safe
compositor as the Medical-Monitor UI is built up incrementally.

Each test drives a full health state for one pixel_clk; the output appears
OSD_LATENCY (=5) cycles later. Most tests choose pixels outside text glyphs so
the result is deterministic background/frame/icon colour; the 2x banner tests
derive expected pixels directly from font8x16.hex.

Layout: waveform 0..599, banner 600..655, cards 656..719.

Run:  software/.venv/bin/python verification/scratch/osd_pixel_test.py
Needs: iverilog, vvp on PATH.
"""

from __future__ import annotations

import shutil
import subprocess
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
DISP = REPO / "rtl/display"
LATENCY = 5
HOLD_CYCLES = 2

COLOR_NORMAL = 0x00CC44
COLOR_ABNORMAL = 0xFFAA00
COLOR_CRITICAL = 0xFF2222
COLOR_WHITE = 0xFFFFFF
COLOR_GRAY = 0x444444
COLOR_DARK = 0x101820
COLOR_FRAME = 0x0088CC
COLOR_WAVE_BG = 0x111111
COLOR_WAVE_GRID = 0x222222
COLOR_EEG = 0x00FF88
COLOR_ECG = 0xFF4444
COLOR_EMG = 0x4488FF
COLOR_ACTIVE = 0x00AAFF


def _load_font_rom() -> list[int]:
    rows: list[int] = []
    for raw in (DISP / "font8x16.hex").read_text().splitlines():
        tok = raw.split("//")[0].strip()
        if tok:
            rows.append(int(tok, 16) & 0xFF)
    if len(rows) < 95 * 16:
        raise RuntimeError(f"font8x16.hex is too short: {len(rows)} rows")
    return rows


FONT_ROM = _load_font_rom()


def _pick_font_pixel(char: str, char_x: int, char_y: int, scale: int, want_on: bool) -> tuple[int, int]:
    """Return one rendered pixel with the requested font bit."""
    base = (ord(char) - 0x20) * 16
    stride = 2 if scale else 1
    for font_row in range(16):
        row_bits = FONT_ROM[base + font_row]
        for font_col in range(8):
            bit_on = ((row_bits >> (7 - font_col)) & 1) == 1
            if bit_on == want_on:
                return char_x + font_col * stride, char_y + font_row * stride
    raise RuntimeError(f"Could not find requested {char!r} glyph pixel")


BANNER_S_FG = _pick_font_pixel("S", 0, 612, 1, True)
BANNER_S_BG = _pick_font_pixel("S", 0, 612, 1, False)
EEG_LABEL_FG = _pick_font_pixel("E", 8, 8, 0, True)
EEG_LABEL_BG = _pick_font_pixel("E", 8, 8, 0, False)

# trig bit map: EEG=4, ECG=3, EMG=2, SpO2=1, Temp=0
# (h, v, de, class, trig, spo2, temp, wave, expected_rgb, name)
TESTS = [
    # banner band (status uses class colour; conf held LOW=gray; AI dark)
    (100,  610, 1, 2, 0,  98, 74, 0, COLOR_CRITICAL, "banner_status_critical"),
    (100,  610, 1, 1, 0,  98, 74, 0, COLOR_ABNORMAL, "banner_status_abnormal"),
    (100,  610, 1, 0, 0,  98, 74, 0, COLOR_NORMAL, "banner_status_normal"),
    (500,  610, 1, 0, 0,  98, 74, 0, COLOR_GRAY, "banner_conf_low_gray"),
    (900,  610, 1, 0, 0,  98, 74, 0, COLOR_DARK, "banner_ai_dark"),
    (BANNER_S_FG[0], BANNER_S_FG[1], 1, 2, 0, 98, 74, 0, COLOR_WHITE, "banner_2x_status_s_fg"),
    (BANNER_S_BG[0], BANNER_S_BG[1], 1, 2, 0, 98, 74, 0, COLOR_CRITICAL, "banner_2x_status_s_bg"),
    (EEG_LABEL_FG[0], EEG_LABEL_FG[1], 1, 0, 0, 98, 74, COLOR_WAVE_BG, COLOR_EEG, "wave_label_eeg_fg"),
    (EEG_LABEL_BG[0], EEG_LABEL_BG[1], 1, 0, 0, 98, 74, COLOR_WAVE_BG, COLOR_WAVE_BG, "wave_label_eeg_bg"),
    # panel frame
    (100,  600, 1, 0, 0,  98, 74, 0, COLOR_FRAME, "frame_top_border"),
    (100,  654, 1, 0, 0,  98, 74, 0, COLOR_FRAME, "frame_band_sep"),
    (400,  610, 1, 0, 0,  98, 74, 0, COLOR_FRAME, "frame_banner_div400"),
    (256,  665, 1, 0, 0,  98, 74, 0, COLOR_FRAME, "frame_card_div256"),
    # cards: inactive (dark) vs active/abnormal (highlighted)
    (100,  665, 1, 0, 0x00, 98, 74, 0, COLOR_DARK, "card_eeg_idle_dark"),
    (100,  665, 1, 0, 0x10, 98, 74, 0, COLOR_ACTIVE, "card_eeg_trig_active"),
    (300,  665, 1, 0, 0x08, 98, 74, 0, COLOR_ACTIVE, "card_ecg_trig_active"),
    (600,  665, 1, 0, 0x04, 98, 74, 0, COLOR_ACTIVE, "card_emg_trig_active"),
    (900,  665, 1, 0, 0x00, 98, 74, 0, COLOR_DARK, "card_spo2_ok_dark"),
    (900,  665, 1, 0, 0x00, 90, 74, 0, COLOR_ABNORMAL, "card_spo2_low_amber"),
    (1100, 665, 1, 0, 0x00, 98, 74, 0, COLOR_DARK, "card_temp_ok_dark"),
    (1100, 665, 1, 0, 0x00, 98, 80, 0, COLOR_ABNORMAL, "card_temp_err_amber"),
    # icon layer (white glyph over background; priority text > icon > bg)
    (314,  622, 1, 0, 0,  98, 74, 0, COLOR_WHITE, "icon_status_check_on"),
    (300,  620, 1, 0, 0,  98, 74, 0, COLOR_NORMAL, "icon_status_off_bg_green"),
    (307,  621, 1, 1, 0,  98, 74, 0, COLOR_WHITE, "icon_status_warning_on"),
    (264,  663, 1, 0, 0,  98, 74, 0, COLOR_WHITE, "icon_ecg_heart_on"),
    (8,    658, 1, 0, 0,  98, 74, 0, COLOR_DARK, "icon_eeg_off_bg_dark"),
    # waveform pass-through + blanking
    (100,  100, 1, 0, 0,  98, 74, COLOR_EEG, COLOR_EEG, "waveform_palette_eeg"),
    (640,  400, 1, 0, 0,  98, 74, COLOR_WAVE_GRID, COLOR_WAVE_GRID, "waveform_palette_grid"),
    (100,  100, 0, 0, 0,  98, 74, 0x123456, 0x000000, "blanking_black"),
]

TB = r"""
`timescale 1ns/1ps
module tb_osd;
    reg clk = 0;
    reg rst_n = 0;
    reg [11:0] hcount = 0, vcount = 0;
    reg de = 0;
    reg [1:0] class_out = 0;
    reg [4:0] trig = 0;
    reg [7:0] spo2 = 98, temp = 74;
    reg [23:0] wave_pixel = 0;
    wire [7:0] r_out, g_out, b_out;

    // packed: [95:84]h [83:72]v [71:70]class [69]de [68:64]trig
    //         [63:56]spo2 [55:48]temp [23:0]wave
    reg [95:0] stim [0:255];
    reg [23:0] cap  [0:255];
    integer n, i;

    osd_overlay u_osd (
        .pixel_clk(clk), .rst_n(rst_n),
        .hcount(hcount), .vcount(vcount), .de(de),
        .class_out(class_out),
        .triggered_sensors(trig), .confidence(2'd0),
        .spo2_raw(spo2), .temp_raw(temp),
        .wave_pixel(wave_pixel),
        .r_out(r_out), .g_out(g_out), .b_out(b_out)
    );

    always #5 clk = ~clk;

    initial begin
        for (i = 0; i < 256; i = i + 1) stim[i] = 96'd0;
        $readmemh("stim.hex", stim);
        n = `NSTIM;

        rst_n = 0; repeat (6) @(posedge clk);
        rst_n = 1; @(negedge clk);

        for (i = 0; i < n + `LATENCY + 4; i = i + 1) begin
            if (i < n) begin
                hcount     = stim[i][95:84];
                vcount     = stim[i][83:72];
                class_out  = stim[i][71:70];
                de         = stim[i][69];
                trig       = stim[i][68:64];
                spo2       = stim[i][63:56];
                temp       = stim[i][55:48];
                wave_pixel = stim[i][23:0];
            end else begin
                de = 0;
            end
            @(posedge clk);
            cap[i] = {r_out, g_out, b_out};
        end
        $writememh("cap.hex", cap);
        $finish;
    end
endmodule
"""


def main() -> int:
    work = Path(tempfile.mkdtemp(prefix="osd_px_"))
    stim_words = []
    for (h, v, de, cls, trig, spo2, temp, wave, _exp, _n) in TESTS:
        word = ((h << 84) | (v << 72) | (cls << 70) | (de << 69) | (trig << 64)
                | (spo2 << 56) | (temp << 48) | (wave & 0xFFFFFF))
        stim_words.extend([word] * HOLD_CYCLES)

    tb = TB.replace("`NSTIM", str(len(stim_words))).replace("`LATENCY", str(LATENCY))
    (work / "tb_osd.v").write_text(tb)
    shutil.copy(DISP / "font8x16.hex", work / "font8x16.hex")
    shutil.copy(DISP / "icon_rom.hex", work / "icon_rom.hex")

    lines = [f"{word:024x}" for word in stim_words]
    (work / "stim.hex").write_text("\n".join(lines) + "\n")

    comp = subprocess.run(
        ["iverilog", "-g2012", "-o", "sim.vvp", "tb_osd.v",
         str(DISP / "osd_overlay.v"), str(DISP / "text_renderer.v")],
        cwd=work, capture_output=True, text=True)
    if comp.returncode != 0:
        print("COMPILE FAILED\n" + comp.stdout + comp.stderr)
        return 1
    run = subprocess.run(["vvp", "sim.vvp"], cwd=work, capture_output=True, text=True)
    if run.returncode != 0:
        print(run.stdout + run.stderr)
        return 1

    cap = []
    for ln in (work / "cap.hex").read_text().splitlines():
        tok = ln.split("//")[0].strip()
        if tok:
            cap.append(-1 if "x" in tok.lower() else int(tok, 16))

    ok = True
    for i, t in enumerate(TESTS):
        h, v, de, exp, name = t[0], t[1], t[2], t[8], t[9]
        cap_idx = i * HOLD_CYCLES + LATENCY
        got = cap[cap_idx] if cap_idx < len(cap) else -1
        status = "OK" if got == exp else "FAIL"
        if got != exp:
            ok = False
        print(f"  {name:26s} ({h:4d},{v:3d}) de={de}: got {got:06X} exp {exp:06X}  {status}")
    print("\n=== OSD pixel test:", "PASS ===" if ok else "FAIL ===")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
