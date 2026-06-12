TOPLEVEL := vga_timing
COCOTB_TEST_MODULES := tests.unit.test_vga_timing

COMPILE_ARGS += -Pvga_timing.H_ACTIVE=8 -Pvga_timing.H_FP=2 -Pvga_timing.H_SYNC=2 -Pvga_timing.H_BP=2
COMPILE_ARGS += -Pvga_timing.V_ACTIVE=4 -Pvga_timing.V_FP=1 -Pvga_timing.V_SYNC=1 -Pvga_timing.V_BP=1

VERILOG_SOURCES := $(RTL_ROOT)/display/vga_timing.v
