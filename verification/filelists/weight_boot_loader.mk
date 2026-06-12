TOPLEVEL := weight_boot_loader
COCOTB_TEST_MODULES := tests.memory.test_weight_boot_loader

VERILOG_SOURCES := $(RTL_ROOT)/common/crc32.v
VERILOG_SOURCES += $(RTL_ROOT)/memory/ddr3_burst_writer.v
VERILOG_SOURCES += $(RTL_ROOT)/memory/weight_boot_loader.v
