TOPLEVEL := cdc_bus_handshake
COCOTB_TEST_MODULES := tests.unit.test_cdc_bus_handshake

VERILOG_SOURCES := $(RTL_ROOT)/common/sync_2ff.v
VERILOG_SOURCES += $(RTL_ROOT)/common/cdc_bus_handshake.v

COMPILE_ARGS += -Pcdc_bus_handshake.WIDTH=9
