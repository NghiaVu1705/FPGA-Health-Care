TOPLEVEL := stft_top
COCOTB_TEST_MODULES := tests.subsystem.test_stft_parity

VERILOG_SOURCES := $(RTL_ROOT)/healthcare_core/stft/fft_radix2_64.v
VERILOG_SOURCES += $(RTL_ROOT)/healthcare_core/stft/stft_top.v
