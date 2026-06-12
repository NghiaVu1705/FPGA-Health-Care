# Makefile - Unified cocotb test runner
.DEFAULT_GOAL := run_test

SIM ?= icarus
WAVES ?= 0
DUT ?= threshold_proc
TOPLEVEL_LANG ?= verilog
# NOTE: asic_top is excluded — the asic/ wrapper + SRAM macro models are not part
# of this repo (Spec 5 documents them but the files are absent), so it cannot be
# elaborated here. Re-add it once asic/ is present.
DUTS ?= threshold_proc decision_layer stft_top stft_parity cnn_top cnn_submodules conv2d_engine_direct fft_radix2_64 severity_mapper uart_top spi_slave i2c_slave cdc_bus_handshake vga_timing waveform_display osd_overlay text_renderer weight_boot_loader weight_boot_loader_crc ddr3_weight_prefetcher weight_cache shared_ai_system shared_ai_timeout shared_ai_full_pipeline top_shared_ai_smoke vendor_boundary full_instance top_lite top_full_lint

VERIF_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
RTL_ROOT   := $(abspath $(VERIF_ROOT)/../rtl)
BUILD_DIR  := $(VERIF_ROOT)/build/$(DUT)/$(SIM)
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

# Simulator settings
ifeq ($(SIM),verilator)
    EXTRA_ARGS += --trace-fst --trace-structs -Wno-fatal
    SIM_BUILD := $(BUILD_DIR)
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

.PHONY: run_test preflight regression coverage coverage_merge clean

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
