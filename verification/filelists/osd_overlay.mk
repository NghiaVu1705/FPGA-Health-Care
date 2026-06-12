TOPLEVEL := osd_overlay
COCOTB_TEST_MODULES := tests.unit.test_osd_overlay
COMPILE_ARGS += -DCOCOTB_SIM
VERILOG_SOURCES := $(RTL_ROOT)/display/text_renderer.v $(RTL_ROOT)/display/osd_overlay.v
