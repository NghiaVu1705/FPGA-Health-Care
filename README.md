# FPGA HealthCare System — Real-Time Multi-Channel Biomedical AI on FPGA

[![FPGA](https://img.shields.io/badge/FPGA-Gowin_GW5AST--LV138-blue)](https://www.gowinsemi.com/en/product/detail/9/)
[![Board](https://img.shields.io/badge/Board-Sipeed_Tang_Mega_138K-green)](https://wiki.sipeed.com/hardware/en/tang/tang-mega-138k/mega-138k-pro.html)
[![HDL](https://img.shields.io/badge/HDL-Verilog-red)](https://en.wikipedia.org/wiki/Verilog)
[![SIM](https://img.shields.io/badge/Sim-cocotb_%2B_Icarus_%2B_Verilator-purple)](https://www.cocotb.org/)
[![Tests](https://img.shields.io/badge/Tests-43%2F43_PASS-brightgreen)](verification/)
[![Coverage](https://img.shields.io/badge/Coverage-100%25_functional-brightgreen)](verification/reports/)
[![Timing](https://img.shields.io/badge/Timing-0_setup_%2F_0_hold-brightgreen)](rtl/constraints/)
[![License](https://img.shields.io/badge/License-Research%2FAcademic-lightgrey)](LICENSE)

> ⚕️ Edge-AI real-time biomedical monitoring system running entirely on FPGA. Acquires EEG, ECG, EMG, SpO₂, and temperature; processes through **STFT → Tiny CNN** for diagnosis; outputs severity alerts + live waveform to HDMI.

**📌 Academic Research Project — NOT a certified medical device.**

---

## 🧠 Overview

This system monitors five biosignal channels simultaneously on a single FPGA chip:

```
EEG (256 Hz) ──┐
ECG (500 Hz) ──┤   ┌──────────┐    ┌─────────────────┐    ┌──────────┐    ┌──────────────┐
EMG (1000 Hz) ─┼──►│ STFT     │───►│ Tiny CNN (INT8) │───►│ Severity │───►│ OSD HDMI     │
SpO₂ ──────────┤   │ 2048-pt  │    │ Depthwise-Sep   │    │ Decision │    │ Waveform +   │
Temp ──────────┘   │ 32×32    │    │ DW+PW ×2 + FC   │    │ 5-source │    │ Alerts       │
                   └──────────┘    └─────────────────┘    └──────────┘    └──────────────┘
```

One shared STFT+CNN lane is **time-multiplexed** across EEG/ECG/EMG with per-channel CNN weights streamed from DDR3 — making a full 3-lane AI pipeline fit on a mid-range FPGA.

---

## 🎯 Key Features

| Feature | Detail |
|---------|--------|
| **Multi-modal** | EEG (seizure), ECG (arrhythmia), EMG (neuromuscular), SpO₂, Temperature |
| **Real-Time DSP** | STFT: 2048 samples → 32 hop × 64-bin → 32×32 spectrogram, Hamming window, Radix-2 FFT |
| **Tiny CNN** | Depthwise-separable INT8: DW+PW+MaxPool ×2 → GlobalMaxPool → FC → 6-class diagnosis |
| **Severity Fusion** | CNN output mapped to 3 levels (Normal/Abnormal/Critical) + vitals threshold → majority-window decision |
| **HDMI Display** | 1280×720@60Hz with live waveform, severity banner, sensor cards, icons |
| **Multi-Sensor Ingress** | UART (EMG), SPI (EEG/ECG), I²C (SpO₂/Temp) |
| **Weight Boot** | ROM image → CRC32 verification → DDR3 streaming → per-channel weight cache |
| **Self-Test Replay** | Onboard button cycles through 3 pre-recorded clinical scenarios |
| **4 Clock Domains** | sys_clk (50 MHz), pixel_clk (73.33 MHz), serial_clk (366.67 MHz), ddr_mem_clk (~400 MHz) |
| **CDC Safety** | Toggle-handshake bus bridge + 2-FF synchronizers + Gray-coded pointers |

---

## 🖥️ Hardware

| Component | Specification |
|-----------|---------------|
| **FPGA** | Gowin GW5AST-LV138PG484AC1/I0 |
| **Board** | Sipeed Tang Mega 138K |
| **Logic Cells** | 138,240 LUT4 |
| **DSP** | 298 (18×18 multipliers) |
| **BSRAM** | 340 blocks |
| **PLL** | 12 |
| **DDR3** | On-board SDRAM via DDR3MI controller |
| **Display** | DVI/HDMI via TMDS @ 1280×720@60 |
| **Toolchain** | Gowin IDE (V1.9.11 Education) |

---

## 📊 Results (Post P&R)

```
Resource Usage (top_shared_ai, device GW5AST-LV138PG484AC1/I0):

  Logic:      44%  (59,560 / 138,240)
  Register:   38%  (52,593 / 139,095)
  CLS:        85%  (58,428 / 69,120)
  DSP:        77%  (229 / 298)
  BSRAM:      23%  (75 / 340)
  I/O:        31%  (91 / 297)

Timing:  0 setup violations, 0 hold violations
Coverage: 43/43 tests PASS, 100% functional (137/137 bins), ≥90% line coverage
```

---

## 📁 Project Structure

```
HealthCare_System/
├── rtl/                          # Synthesizable RTL (Verilog)
│   ├── top/                      # Top-level designs
│   │   ├── top_shared_ai.v       # ★ MAIN TOP (Final build target)
│   │   ├── top.v                 # Alternative top (parameterized)
│   │   └── top_full_arch.v       # Full architecture (3-lane, study only)
│   ├── system/                   # System integration
│   │   ├── biomed_shared_ai_system.v   # Shared-AI core (1-lane time-mux)
│   │   └── biomed_full_system.v        # Full 3-lane wrapper
│   ├── healthcare_core/
│   │   ├── stft/                 # STFT pipeline
│   │   │   ├── stft_top.v        # STFT orchestrator
│   │   │   ├── fft_radix2_64.v   # Radix-2 64-pt FFT
│   │   │   ├── hamming_window.v
│   │   │   └── magnitude_calc.v
│   │   ├── cnn_accelerator/      # CNN accelerator
│   │   │   ├── cnn_top.v         # CNN orchestrator
│   │   │   ├── conv2d_engine.v   # DW/PW conv (5-stage pipeline)
│   │   │   ├── fc_layer.v        # Fully-connected + argmax
│   │   │   ├── maxpool_unit.v
│   │   │   ├── global_maxpool_unit.v
│   │   │   ├── mac_unit.v
│   │   │   └── relu_unit.v
│   │   ├── decision/             # Decision fusion
│   │   │   └── decision_layer.v
│   │   └── threshold/
│   │       └── threshold_proc.v
│   ├── memory/                   # Memory subsystem
│   │   ├── weight_boot_loader.v  # ROM→DDR3 boot with CRC32
│   │   ├── ddr3_burst_writer.v   # Byte stream → 256-bit DDR3 bursts
│   │   ├── ddr3_weight_prefetcher.v  # DDR3 → local cache
│   │   └── weight_cache_512x8.v
│   ├── serial_comm/              # Sensor interfaces
│   │   ├── uart/                 # UART RX/TX (EMG)
│   │   ├── spi_slave/            # SPI slave (EEG/ECG)
│   │   └── i2c_slave/            # I²C slave (SpO₂/Temp)
│   ├── display/                  # HDMI video pipeline
│   │   ├── vga_timing.v
│   │   ├── waveform_display.v
│   │   ├── osd_overlay.v
│   │   └── text_renderer.v
│   ├── common/                   # Shared utilities
│   │   ├── cdc_bus_handshake.v   # Multi-bit CDC (toggle handshake)
│   │   ├── sync_2ff.v            # 2-FF synchronizer
│   │   ├── reset_sync.v          # Reset synchronizer
│   │   ├── sync_fifo.v           # Synchronous FIFO
│   │   ├── crc32.v               # CRC32 (IEEE 802.3)
│   │   ├── clock_divider.v
│   │   └── sram_sp.v             # Single-port SRAM
│   ├── gowin_ip/                 # Gowin vendor IP wrappers
│   └── constraints/
│       ├── 138K_DOCK.cst         # Pin assignments
│       └── Final.sdc             # Timing constraints
├── software/                     # Python ML pipeline
│   ├── train.py                  # Float pretrain + QAT fine-tune
│   ├── export_weights.py         # INT8 weight export (hex + pack)
│   ├── pack_weight_image.py      # Weight image packing for DDR3
│   ├── inference.py              # Sample inference
│   ├── common/
│   │   ├── model.py              # TinyCNN PyTorch (matching RTL)
│   │   ├── cnn_reference.py      # Numpy reference (bit-exact)
│   │   └── weight_image.py       # Weight image data structures
│   ├── preprocess/               # STFT preprocess (bit-exact with RTL)
│   ├── datasets/                 # Data generation & loading
│   ├── dataset/                  # Training data (.npy)
│   ├── checkpoints/              # Trained models (.pt)
│   └── weights/                  # Exported INT8 weights (.hex)
├── verification/                 # Cocotb test suite
│   ├── tests/                    # Unit / subsystem / integration tests
│   ├── models/                   # Sim stubs for Gowin IP
│   ├── filelists/                # Per-DUT Verilog filelists
│   ├── sva/                      # SystemVerilog Assertions
│   ├── coverage/                 # Coverage collection
│   └── Makefile                  # Unified test runner
├── docs/                         # Documentation
│   ├── Spec.md                   # Module catalog & specifications
│   ├── Block_Diagram.md          # Block diagrams (Mermaid + ASCII)
│   ├── software.md               # ML improvement roadmap
│   └── HealthCare.drawio         # Draw.io diagrams
├── Gowin/                        # Gowin IDE project
│   ├── Gowin.gprj                # Project file
│   └── impl/pnr/Final.fs         # Compiled bitstream
└── paper/                        # Academic paper
```

---

## 🚀 Getting Started

### Prerequisites

**FPGA Build:**
- [Gowin IDE](https://www.gowinsemi.com/en/support/download_eda/) (V1.9.9+ Education)
- Sipeed Tang Mega 138K board (or GW5AST-LV138 development board)

**Simulation & Verification:**
- Python 3.12+
- [Icarus Verilog](http://iverilog.icarus.com/) (`brew install icarus-verilog`)
- [Verilator](https://www.verilator.org/) (`brew install verilator`)
- [cocotb](https://www.cocotb.org/) (`pip install cocotb`)
- [GTKWave](https://gtkwave.sourceforge.net/) (optional, for waveform viewing)

**Software (ML Pipeline):**
- PyTorch 2.2+, NumPy, SciPy (`pip install -r software/requirements.txt`)

### Quick Start — Simulation

```bash
# Setup Python environment
cd verification
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt

# Run single test
make DUT=threshold_proc SIM=icarus

# Run full regression (all 43 tests)
make regression SIM=icarus WAVES=0

# Run with Verilator + code coverage
make coverage_code

# Run SVA assertions (Verilator only)
make assertions

# Multi-seed random stability
make regression_seeds
```

### Quick Start — FPGA Bitstream

```bash
# 1. Open Gowin IDE
# 2. File → Open Project → Gowin/Gowin.gprj
# 3. Set Top Module = "top_shared_ai"
# 4. Run Synthesis → Place & Route → Generate Bitstream
# 5. Program device with Gowin/impl/pnr/Final.fs
```

### Quick Start — ML Pipeline

```bash
cd software

# Install dependencies
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt

# Train models (EEG/ECG/EMG)
python train.py --device cpu --pretrain-epochs 30 --qat-epochs 15

# Export INT8 weights for RTL
python export_weights.py
```

---

## 🔬 Architecture Details

### Shared-AI Core Datapath

```
PREFETCH → RESET → CNN_LOAD → COLLECT → WAIT → NEXT ──┐
    ↑                                                   │
    └─────────────── (next channel) ◄───────────────────┘

Channel Round-Robin:  EEG (CH0) → ECG (CH1) → EMG (CH2) → EEG ...

Per Channel:
  1. PREFETCH: 16 × 256-bit DDR3 reads → 512 B weight tile → local cache
  2. RESET:    15-cycle pipeline flush (functional clear, not async reset)
  3. CNN_LOAD: 512 cycles for CNN to copy cache into internal weight registers
  4. COLLECT:  Accumulate 2048 samples → STFT → 32×32 spectrogram
  5. WAIT:     CNN inference (watchdog: 1,000,000 cycles)
  6. NEXT:     Latch CNN result, advance channel
```

### CNN Topology (INT8 Quantized)

```
Input: 32×32×1 (spectrogram)

Block 1:
  DW Conv 3×3, 1ch ──► ReLU ──► PW Conv 1×1, 1→8 ──► ReLU ──► MaxPool2×2 → 16×16×8

Block 2:
  DW Conv 3×3, 8ch ──► ReLU ──► PW Conv 1×1, 8→16 ──► ReLU ──► MaxPool2×2 → 8×8×16

Global MaxPool → 16
FC 16 → NUM_CLASSES (6) ──► argmax

Shifts: DW1=7, PW1=7, DW2=7, PW2=6, FC=auto-calibrated
```

### Clock Domains

| Domain | Frequency | Used By |
|--------|-----------|---------|
| 🟦 `sys_clk` | 50 MHz | Core logic, sensors, STFT, CNN, DDR3 ctrl |
| 🟧 `pixel_clk` | 73.333 MHz | VGA timing, waveform, OSD, text renderer |
| 🟥 `serial_clk` | 366.667 MHz | TMDS/DVI serializer |
| 🟩 `ddr_mem_clk` | ~400 MHz | DDR3 PHY |

CDC crossings: `cdc_bus_handshake` (decision bundle 9-bit) + `sync_2ff` (status flags) + Gray code (waveform pointers).

---

## 📈 Verification

| Metric | Value |
|--------|-------|
| **Designs Under Test** | 29 |
| **Tests** | 43 |
| **Pass Rate** | 100% (43/43) |
| **Functional Coverage** | 100% (137/137 coverage bins) |
| **Line Coverage (Verilator)** | ≥ 90% (core RTL) |
| **SVA Assertions** | 4 modules (FSM, decision, prefetcher) |
| **Multi-Seed Testing** | 10 seeds × 4 DUTs (constrained-random) |
| **Simulators** | Icarus Verilog + Verilator |

Test categories:
- **Unit:** Individual modules (cnn_submodules, conv2d_engine, fc_layer, fft_radix2, decision, threshold, uart, spi, i2c, vga, waveform, osd, text, CDC, etc.)
- **Subsystem:** STFT parity, CNN top parity
- **Integration:** Full pipeline, shared-AI system, top-level smoke, vendor boundary
- **Memory:** Weight boot loader (with/without CRC), DDR3 prefetcher, weight cache

---

## ⚠️ Disclaimer

**This is an academic research project (NCKH). It is NOT a certified medical device.** Not for clinical diagnostic use. Any diagnosis, treatment, or health decision must involve qualified medical professionals and comply with relevant regulations (FDA, CE, etc.). The authors make no claims of fitness for any medical purpose.

---

## 📚 References

- AAMI EC57: Testing and Reporting Performance Results of Cardiac Rhythm and ST Segment Measurement Algorithms
- de Chazal et al., "Automatic Classification of Heartbeats Using ECG Morphology and Heartbeat Interval Features", IEEE TBME 2004
- MIT-BIH Arrhythmia Database (PhysioNet)
- CHB-MIT Scalp EEG Database (PhysioNet)
- Ninapro Database (sEMG gesture)
- Gowin GW5AST-138 FPGA Datasheet
- Sipeed Tang Mega 138K Documentation

---

## 📄 License

This project is released for research and educational purposes. See individual source files for specific copyright notices on vendor IP (Gowin PLL/DDR3MI/DVI_TX wrappers).

---

*Last updated: June 2026 · Built with Gowin IDE V1.9.11 Education · Simulated with cocotb 1.9+*
