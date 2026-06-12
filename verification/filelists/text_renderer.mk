TOPLEVEL := text_renderer
COCOTB_TEST_MODULES := tests.unit.test_text_renderer
COMPILE_ARGS += -DCOCOTB_SIM
VERILOG_SOURCES := $(RTL_ROOT)/display/text_renderer.v
