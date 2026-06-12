#!/usr/bin/env python3
"""Self-contained byte-exact CNN parity check (Icarus Verilog, no cocotb).

This script verifies that the NumPy-based CNN reference model
(``software/common/cnn_reference.py``) is 100% bit-exact and byte-identical
to the hardware RTL accelerator across all 3 modalities (EEG, ECG, EMG).

It generates random spectrogram inputs, loads the real weight HEX files,
runs both the software model and the compiled RTL simulation, and asserts
that the computed logits and predicted classes match exactly.

Run:  python verification/scratch/cnn_parity_iverilog.py
Needs: iverilog, vvp on PATH; numpy in the active venv.
"""

from __future__ import annotations

import argparse
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np

# Resolve repo root and paths
REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "software"))

from common.cnn_reference import cnn_forward  # noqa: E402
from common.weight_image import decode_weight_image  # noqa: E402

CNN_RTL = REPO / "rtl/healthcare_core/cnn_accelerator"
DEFAULT_RTL_WEIGHTS = {
    "EEG": REPO / "rtl/gowin_bsram/eeg/cnn_weights.hex",
    "ECG": REPO / "rtl/gowin_bsram/ecg/cnn_weights.hex",
    "EMG": REPO / "rtl/gowin_bsram/emg/cnn_weights.hex",
}

TB_TEMPLATE = r"""
`timescale 1ns/1ps
module tb_cnn_parity;
    localparam integer N_CLASSES = __N_CLASSES__;
    localparam integer CLASS_BITS = (N_CLASSES <= 2) ? 1 : $clog2(N_CLASSES);

    reg sys_clk = 0;
    reg rst_n = 0;
    reg [7:0] spec_in = 0;
    reg spec_valid = 0;
    reg spec_start = 0;
    wire [CLASS_BITS-1:0] class_out;
    wire class_valid;
    wire [8:0] bsram_addr;
    reg [7:0] bsram_data = 0;

    reg [7:0] weight_rom [0:511];
    reg [7:0] spec_mem    [0:1023];
    integer i;
    integer j;

    always #5 sys_clk = ~sys_clk;

    // Registered (1-cycle) BSRAM read, matching weight_cache_512x8's registered
    // output. cnn_top's load FSM (bsram_prev = load_addr-2) accounts for it.
    always @(posedge sys_clk) begin
        bsram_data <= weight_rom[bsram_addr];
    end

    cnn_top #(.NUM_CLASSES(N_CLASSES), .CLASS_BITS(CLASS_BITS)) dut (
        .sys_clk(sys_clk), .rst_n(rst_n),
        .spec_in(spec_in), .spec_valid(spec_valid), .spec_start(spec_start),
        .class_out(class_out), .class_valid(class_valid),
        .bsram_addr(bsram_addr), .bsram_data(bsram_data)
    );

    initial begin
        $readmemh("weights.hex", weight_rom);
        $readmemh("spec.hex", spec_mem);

        rst_n = 0; repeat (8) @(posedge sys_clk);
        rst_n = 1; repeat (4) @(posedge sys_clk);

        // Wait until weights are fully loaded into internal registers
        // state 1 is ST_READY
        while (dut.state != 3'd1) @(posedge sys_clk);

        repeat (2) @(posedge sys_clk);

        // Start streaming spectrogram
        @(negedge sys_clk);
        spec_start = 1;
        spec_in = spec_mem[0];
        spec_valid = 1;

        @(negedge sys_clk);
        spec_start = 0;

        for (i = 1; i < 1024; i = i + 1) begin
            spec_in = spec_mem[i];
            spec_valid = 1;
            @(negedge sys_clk);
        end
        spec_valid = 0;
        spec_in = 0;

        // Wait for inference complete
        i = 0;
        while (!class_valid && i < 200000) begin
            @(posedge sys_clk);
            i = i + 1;
        end

        if (!class_valid) begin
            $display("ERROR: timeout waiting for class_valid");
            $finish;
        end

        // Output results to stdout so python can parse it
        $display("CLASS: %0d", class_out);
        $write("LOGITS:");
        for (j = 0; j < N_CLASSES; j = j + 1) begin
            $write(" %0d", $signed(dut.u_fc.logits[(j*8)+:8]));
        end
        $write("\n");
        $finish;
    end
endmodule
"""


def _write_hex_bytes(path: Path, values):
    path.write_text("\n".join(f"{int(v) & 0xFF:02x}" for v in values) + "\n")


def _read_hex_image(path: Path) -> list[int]:
    data = []
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or line.startswith("//"):
            continue
        data.append(int(line, 16) & 0xFF)
    return data + [0] * (512 - len(data))


def _weights_for_args(weights_dir: Path | None) -> list[tuple[str, Path]]:
    if weights_dir is None:
        return [(name, path) for name, path in DEFAULT_RTL_WEIGHTS.items()]

    weights_dir = weights_dir.resolve()
    items = []
    for name in ("EEG", "ECG", "EMG"):
        mod = name.lower()
        candidates = [
            weights_dir / f"{mod}_weights.hex",
            weights_dir / f"{mod}_cnn_weights.hex",
            weights_dir / mod / "cnn_weights.hex",
        ]
        for path in candidates:
            if path.exists():
                items.append((name, path))
                break
        else:
            raise FileNotFoundError(f"no weight HEX found for {name} under {weights_dir}")
    return items


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--n-classes", type=int, default=3)
    parser.add_argument(
        "--weights-dir",
        type=Path,
        default=None,
        help="Directory containing eeg_weights.hex/ecg_weights.hex/emg_weights.hex. "
             "Defaults to the RTL Gowin BSRAM weight files.",
    )
    parser.add_argument("--frames", type=int, default=3, help="Random frames per modality.")
    parser.add_argument("--seed", type=int, default=42)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    work = Path(tempfile.mkdtemp(prefix="cnn_parity_"))
    tb = TB_TEMPLATE.replace("__N_CLASSES__", str(args.n_classes))
    (work / "tb_cnn_parity.v").write_text(tb)

    # List of RTL files to compile
    rtl_files = [
        str(CNN_RTL / "cnn_top.v"),
        str(CNN_RTL / "conv2d_engine.v"),
        str(CNN_RTL / "fc_layer.v"),
        str(CNN_RTL / "global_maxpool_unit.v"),
        str(CNN_RTL / "mac_unit.v"),
        str(CNN_RTL / "maxpool_unit.v"),
        str(CNN_RTL / "relu_unit.v"),
    ]

    print("Compiling RTL with iverilog...")
    subprocess.run(
        ["iverilog", "-g2012", "-o", "sim.vvp", "tb_cnn_parity.v"] + rtl_files,
        cwd=work,
        check=True,
        capture_output=True,
        text=True,
    )

    modalities = _weights_for_args(args.weights_dir)

    all_ok = True
    rng = np.random.default_rng(args.seed)

    for modality, hex_path in modalities:
        print(f"\nEvaluating {modality} model ({hex_path.name})...")
        # Read and decode weight parameters for the python model
        raw_weights = _read_hex_image(hex_path)
        params = decode_weight_image(raw_weights, n_classes=args.n_classes)
        _write_hex_bytes(work / "weights.hex", raw_weights)

        for f_idx in range(args.frames):
            # Spectrogram values in range [0, 127]
            spec = rng.integers(0, 128, size=(32, 32), dtype=np.uint8)
            _write_hex_bytes(work / "spec.hex", spec.reshape(-1))

            # Run python model
            res = cnn_forward(spec, params)
            py_class = int(res["class"])
            py_logits = [int(v) for v in res["logits"]]

            # Run RTL simulation
            proc = subprocess.run(
                ["vvp", "sim.vvp"], cwd=work, check=True, capture_output=True, text=True
            )
            stdout = proc.stdout

            # Parse simulation results
            rtl_class = None
            rtl_logits = []
            for line in stdout.splitlines():
                if line.startswith("CLASS:"):
                    rtl_class = int(line.split()[1])
                elif line.startswith("LOGITS:"):
                    parts = line.split()
                    rtl_logits = [int(v) for v in parts[1:]]

            if rtl_class is None or len(rtl_logits) != args.n_classes:
                print(f"  Frame {f_idx}: Failed to parse simulation output.  FAIL")
                all_ok = False
                continue

            # Compare
            logits_match = py_logits == rtl_logits
            class_match = py_class == rtl_class
            ok = logits_match and class_match
            all_ok &= ok

            status = "EXACT" if ok else "MISMATCH"
            print(f"  Frame {f_idx}: {status}")
            print(f"    Python Logits: {py_logits} -> Class {py_class}")
            print(f"    RTL Logits:    {rtl_logits} -> Class {rtl_class}")

    print("\n=== CNN parity:", "BYTE-EXACT ===" if all_ok else "FAILURES FOUND ===")
    return 0 if all_ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
