#!/usr/bin/env python3
"""Self-contained byte-exact STFT parity check (Icarus Verilog, no cocotb).

The official parity test is the cocotb one
(``verification/tests/subsystem/test_stft_parity.py``), but that needs the
cocotb verification venv.  This script proves the *same* property using only
``iverilog`` + ``vvp`` and the software model — handy when cocotb isn't set up.

It streams several 2048-sample stimuli through ``stft_top`` and asserts the
emitted 32x32 spectrogram is byte-identical to
``software/preprocess/stft_transform.spectrogram``.

Run:  python verification/scratch/stft_parity_iverilog.py
Needs: iverilog, vvp on PATH; numpy in the active venv.
"""

from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "software"))
from preprocess.stft_transform import load_roms, spectrogram  # noqa: E402

STFT_RTL = REPO / "rtl/healthcare_core/stft"
HAMMING_HEX = REPO / "rtl/gowin_bsram/hamming_coeff_rom.hex"
TWIDDLE_HEX = REPO / "rtl/gowin_bsram/fft_twiddle_rom.hex"
N_SAMPLES = 2048

# 1-cycle synchronous ROM read + sample streaming; dumps the 1024 spectrogram
# bytes to spec_out.hex.  Mirrors the cocotb _drive_sync_roms timing exactly.
TB = r"""
`timescale 1ns/1ps
module tb_parity;
    reg sys_clk = 0;
    reg rst_n = 0;
    reg signed [15:0] sample_in = 0;
    reg sample_valid = 0;
    wire [7:0] spec_out;
    wire spec_valid;
    reg spec_ready = 1;
    wire [5:0] hamming_rom_addr;
    reg  [7:0] hamming_rom_data = 0;
    wire [4:0] twiddle_rom_addr;
    reg  [31:0] twiddle_rom_data = 0;

    reg [7:0]  hamming_mem [0:63];
    reg [31:0] twiddle_mem [0:31];
    reg [15:0] samples     [0:2047];
    reg [7:0]  spec_cap    [0:1023];
    integer i, ncap = 0;

    always #5 sys_clk = ~sys_clk;
    always @(posedge sys_clk) begin
        hamming_rom_data <= hamming_mem[hamming_rom_addr];
        twiddle_rom_data <= twiddle_mem[twiddle_rom_addr];
    end

    stft_top dut (
        .sys_clk(sys_clk), .rst_n(rst_n),
        .sample_in(sample_in), .sample_valid(sample_valid),
        .spec_out(spec_out), .spec_valid(spec_valid), .spec_ready(spec_ready),
        .hamming_rom_addr(hamming_rom_addr), .hamming_rom_data(hamming_rom_data),
        .twiddle_rom_addr(twiddle_rom_addr), .twiddle_rom_data(twiddle_rom_data)
    );

    always @(posedge sys_clk) begin
        if (spec_valid && ncap < 1024) begin
            spec_cap[ncap] = spec_out;   // blocking: settled before $writememh
            ncap = ncap + 1;
        end
    end

    initial begin
        $readmemh("hamming.hex", hamming_mem);
        $readmemh("twiddle.hex", twiddle_mem);
        $readmemh("samples.hex", samples);
        rst_n = 0; repeat (8) @(posedge sys_clk);
        rst_n = 1; repeat (4) @(posedge sys_clk);
        for (i = 0; i < 2048; i = i + 1) begin
            @(negedge sys_clk); sample_in = samples[i]; sample_valid = 1;
        end
        @(negedge sys_clk); sample_valid = 0; sample_in = 0;
        i = 0;
        while (ncap < 1024 && i < 400000) begin @(posedge sys_clk); i = i + 1; end
        if (ncap != 1024) begin $display("ERROR: only %0d bytes", ncap); $finish; end
        repeat (2) @(posedge sys_clk);
        $writememh("spec_out.hex", spec_cap);
        $finish;
    end
endmodule
"""


def _stimuli():
    n = np.arange(N_SAMPLES)
    raw = [
        ("sine_amp400_bin8", np.rint(400.0 * np.sin(2 * np.pi * 8 * n / 64.0))),
        ("sine_amp20000_bin8", np.rint(20000.0 * np.sin(2 * np.pi * 8 * n / 64.0))),
        ("multitone_3_8_13", np.rint(
            300.0 * np.sin(2 * np.pi * 3 * n / 64.0)
            + 200.0 * np.sin(2 * np.pi * 8 * n / 64.0)
            + 150.0 * np.sin(2 * np.pi * 13 * n / 64.0))),
        ("dc_min_overflow", np.full(N_SAMPLES, -32768)),
        ("silence", np.zeros(N_SAMPLES)),
    ] + [(f"random_seed{s}", np.random.default_rng(s).integers(-32768, 32768, size=N_SAMPLES))
         for s in range(4)]
    return [(name, np.asarray(s).astype(np.int16)) for name, s in raw]


def _write_hex(path: Path, values, width):
    fmt = f"{{:0{width}x}}"
    path.write_text("\n".join(fmt.format(int(v) & ((1 << (4 * width)) - 1)) for v in values) + "\n")


def main() -> int:
    ham, tw = load_roms(HAMMING_HEX, TWIDDLE_HEX)
    work = Path(tempfile.mkdtemp(prefix="stft_parity_"))
    (work / "tb_parity.v").write_text(TB)
    _write_hex(work / "hamming.hex", ham, 2)
    _write_hex(work / "twiddle.hex", tw, 8)

    subprocess.run(
        ["iverilog", "-g2012", "-o", "sim.vvp", "tb_parity.v",
         str(STFT_RTL / "stft_top.v"), str(STFT_RTL / "fft_radix2_64.v")],
        cwd=work, check=True, capture_output=True, text=True)

    all_ok = True
    for name, samples in _stimuli():
        _write_hex(work / "samples.hex", [int(s) & 0xFFFF for s in samples], 4)
        subprocess.run(["vvp", "sim.vvp"], cwd=work, check=True, capture_output=True, text=True)
        rtl = np.array(
            [int(ln.strip(), 16) for ln in (work / "spec_out.hex").read_text().splitlines()
             if ln.strip() and not ln.lstrip().startswith("//")], dtype=int)
        model = spectrogram(samples, ham, tw).reshape(-1).astype(int)
        if rtl.shape[0] != 1024:
            print(f"  {name:20s}: RTL emitted {rtl.shape[0]} bytes  FAIL")
            all_ok = False
            continue
        d = np.abs(rtl - model)
        ok = bool((d == 0).all())
        all_ok &= ok
        status = "EXACT" if ok else f"MISMATCH n={int((d != 0).sum())} max|d|={int(d.max())}"
        print(f"  {name:20s}: {status}")

    print("\n=== STFT parity:", "BYTE-EXACT ===" if all_ok else "FAILURES FOUND ===")
    return 0 if all_ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
