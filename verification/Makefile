# Makefile - Unified cocotb test runner
.DEFAULT_GOAL := run_test

SIM ?= icarus
WAVES ?= 0
# CODE_COV=1 enables Verilator build-time code coverage (see coverage_code).
# NB: do NOT name this COVERAGE — that env var is reserved by cocotb for Python
# user-coverage and collides with this repo's local `coverage/` package.
CODE_COV ?= 0
DUT ?= threshold_proc
TOPLEVEL_LANG ?= verilog
# NOTE: asic_top is excluded — the asic/ wrapper + SRAM macro models are not part
# of this repo (Spec 5 documents them but the files are absent), so it cannot be
# elaborated here. Re-add it once asic/ is present.
DUTS ?= threshold_proc decision_layer stft_top stft_parity cnn_top cnn_submodules conv2d_engine_direct fft_radix2_64 severity_mapper uart_top spi_slave i2c_slave cdc_bus_handshake vga_timing waveform_display osd_overlay text_renderer weight_boot_loader weight_boot_loader_crc ddr3_weight_prefetcher weight_cache shared_ai_system shared_ai_timeout shared_ai_full_pipeline top_shared_ai_smoke vendor_boundary full_instance top_lite top_full_lint

VERIF_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
RTL_ROOT   := $(abspath $(VERIF_ROOT)/../rtl)
# Code-coverage builds go to a separate dir so they never collide with (or skip
# rebuilding over) the normal non-instrumented Verilator/Icarus build.
COV_SUFFIX :=
ifeq ($(CODE_COV),1)
COV_SUFFIX := _cov
endif
BUILD_DIR  := $(VERIF_ROOT)/build/$(DUT)/$(SIM)$(COV_SUFFIX)
LOG_DIR    := $(VERIF_ROOT)/logs
REPORT_DIR := $(VERIF_ROOT)/reports
WAVE_DIR   := $(VERIF_ROOT)/waves

export PYTHONPATH := $(VERIF_ROOT):$(PYTHONPATH)
export RTL_ROOT
export TOPLEVEL_LANG
export FUNCTIONAL_COVERAGE_FILE := $(REPORT_DIR)/$(DUT)_$(SIM)_coverage.jsonl

# Create necessary directories
$(shell mkdir -p $(BUILD_DIR) $(LOG_DIR) $(REPORT_DIR) $(WAVE_DIR))

# Include filelist for the selected DUT
include $(VERIF_ROOT)/filelists/$(DUT).mk

# SVA assertions (Verilator only — Icarus 13 supports neither concurrent SVA nor
# bind). ASSERT=1 pulls in sva/$(DUT)_sva.sv (concurrent assert property + bind)
# and enables --assert so a violated property aborts the sim (test fails).
SVA_DIR := $(VERIF_ROOT)/sva
ifeq ($(ASSERT),1)
ifeq ($(SIM),verilator)
VERILOG_SOURCES += $(wildcard $(SVA_DIR)/$(DUT)_sva.sv)
COMPILE_ARGS += --assert
endif
endif

# Simulator settings
ifeq ($(SIM),verilator)
    EXTRA_ARGS += --trace-fst --trace-structs -Wno-fatal
    SIM_BUILD := $(BUILD_DIR)
    # Build-time LINE code-coverage instrumentation. Must be in COMPILE_ARGS
    # (verilate step), NOT EXTRA_ARGS (which also reaches the runtime executable).
    # cocotb's verilator.cpp writes coverage.dat on finish. Toggle coverage is
    # intentionally NOT enabled: this is a memory/bus-heavy DSP design (2048-deep
    # sample buffers, wide spectrogram/weight arrays), so toggle points are
    # dominated by data bits a directed test never fully exercises and are not a
    # meaningful gate. Line coverage measures "was the RTL executed".
    ifeq ($(CODE_COV),1)
        COMPILE_ARGS += --coverage-line
    endif
else
    COMPILE_ARGS += -g2005-sv
    SIM_BUILD := $(BUILD_DIR)
endif

ifeq ($(SIM),icarus)
    ifeq ($(shell command -v iverilog 2>/dev/null),)
        ICARUS_BIN_DIR := /__missing_icarus__
    endif
endif

COCOTB_RESULTS_FILE := $(REPORT_DIR)/$(DUT)_$(SIM)_results.xml

# Synthesizable owned-RTL DUTs that elaborate cleanly under Verilator for code
# (line + toggle) coverage. conv2d_engine_direct is excluded (its filelist uses
# the Icarus-only -P param override); conv2d is covered transitively via cnn_top.
COV_DUTS ?= threshold_proc decision_layer fft_radix2_64 severity_mapper stft_top cnn_top cnn_submodules weight_boot_loader ddr3_weight_prefetcher weight_cache shared_ai_system shared_ai_full_pipeline osd_overlay text_renderer waveform_display spi_slave
COV_CODE_DIR := $(REPORT_DIR)/code_coverage

# DUTs carrying SVA bind checkers (sva/<dut>_sva.sv). Verilator-only.
SVA_DUTS ?= decision_layer weight_boot_loader ddr3_weight_prefetcher shared_ai_system

# Random-stability: DUTs with constrained-random stimulus, swept over many seeds.
SEED_DUTS ?= threshold_proc decision_layer conv2d_engine_direct stft_top
SEEDS     ?= 1 2 3 4 5 6 7 8 9 10

.PHONY: run_test preflight regression coverage coverage_merge coverage_code assertions regression_seeds clean

run_test: preflight
	@rm -f $(FUNCTIONAL_COVERAGE_FILE)
	@bash -o pipefail -c '$(MAKE) --no-print-directory sim DUT=$(DUT) SIM=$(SIM) SIM_BUILD=$(BUILD_DIR) COCOTB_RESULTS_FILE=$(COCOTB_RESULTS_FILE) 2>&1 | tee $(LOG_DIR)/$(DUT)_$(SIM).log'

regression: preflight
	@set -e; \
	for dut in $(DUTS); do \
		printf '\n==== Running DUT=%s SIM=$(SIM) ====\n' "$$dut"; \
		$(MAKE) --no-print-directory run_test DUT=$$dut SIM=$(SIM) WAVES=$(WAVES); \
	done

coverage: regression coverage_merge

coverage_merge:
	@python -m coverage.functional_coverage merge --plan $(VERIF_ROOT)/coverage/coverage_plan.json --reports $(REPORT_DIR)

# Verilator line+toggle code coverage over the synthesizable owned-RTL DUTs.
# Each DUT is rebuilt instrumented (CODE_COV=1 -> separate _cov build dir),
# emits coverage.dat in the run cwd, which is collected per-DUT and merged.
coverage_code:
	@command -v verilator >/dev/null 2>&1 || { echo "ERROR: verilator not found"; exit 127; }
	@mkdir -p $(COV_CODE_DIR)
	@rm -f $(COV_CODE_DIR)/*.dat
	@set -e; for dut in $(COV_DUTS); do \
		printf '\n==== code coverage DUT=%s ====\n' "$$dut"; \
		rm -f $(VERIF_ROOT)/coverage.dat; \
		$(MAKE) --no-print-directory run_test DUT=$$dut SIM=verilator CODE_COV=1 WAVES=0; \
		if [ -f $(VERIF_ROOT)/coverage.dat ]; then \
			mv $(VERIF_ROOT)/coverage.dat $(COV_CODE_DIR)/$$dut.dat; \
		else \
			echo "WARN: no coverage.dat produced for $$dut"; \
		fi; \
	done
	@echo "\n---- merging code coverage ----"
	@verilator_coverage --annotate $(COV_CODE_DIR)/annotated --write-info $(COV_CODE_DIR)/merged.info $(COV_CODE_DIR)/*.dat > $(COV_CODE_DIR)/verilator_coverage.txt 2>&1
	@python -m coverage.code_cov_summary $(COV_CODE_DIR)/merged.info $(COV_CODE_DIR)/line_coverage.md
	@echo "Annotated sources + line_coverage.md in $(COV_CODE_DIR)"

# SVA assertion runs (Verilator --assert). A violated concurrent property aborts
# the sim, which surfaces as a failed cocotb test. All DUTs must report PASS.
assertions:
	@command -v verilator >/dev/null 2>&1 || { echo "ERROR: verilator not found"; exit 127; }
	@set -e; for dut in $(SVA_DUTS); do \
		printf '\n==== SVA DUT=%s ====\n' "$$dut"; \
		$(MAKE) --no-print-directory run_test DUT=$$dut SIM=verilator ASSERT=1 WAVES=0; \
	done
	@echo "\nAll SVA assertion runs passed (no property violated)."

# Multi-seed random stability: re-run the constrained-random DUTs across many
# cocotb seeds. Any seed-dependent failure (random instability) shows up as a
# non-PASS for that seed. Override with SEEDS="..." / SEED_DUTS="...".
regression_seeds: preflight
	@set -e; for s in $(SEEDS); do \
		for dut in $(SEED_DUTS); do \
			printf '\n==== seed=%s DUT=%s ====\n' "$$s" "$$dut"; \
			COCOTB_RANDOM_SEED=$$s $(MAKE) --no-print-directory run_test DUT=$$dut SIM=$(SIM) WAVES=0; \
		done; \
	done
	@echo "\nAll seeds passed for: $(SEED_DUTS)"

preflight:
	@if [ "$(SIM)" = "icarus" ]; then \
		command -v iverilog >/dev/null 2>&1 || { printf '%s\n' "ERROR: iverilog not found. Install simulator tools with: brew install icarus-verilog verilator gtkwave"; exit 127; }; \
		command -v vvp >/dev/null 2>&1 || { printf '%s\n' "ERROR: vvp not found. Install simulator tools with: brew install icarus-verilog verilator gtkwave"; exit 127; }; \
	fi
	@if [ "$(SIM)" = "verilator" ]; then \
		command -v verilator >/dev/null 2>&1 || { printf '%s\n' "ERROR: verilator not found. Install simulator tools with: brew install icarus-verilog verilator gtkwave"; exit 127; }; \
	fi

clean::
	rm -rf build/ logs/ waves/ reports/ __pycache__

# Include cocotb makefiles
COCOTB_MAKEFILES := $(shell cocotb-config --makefiles 2>/dev/null)
ifeq ($(COCOTB_MAKEFILES),)
$(error "cocotb-config not found. Please install Python requirements: pip install -r requirements.txt")
endif
include $(COCOTB_MAKEFILES)/Makefile.sim
