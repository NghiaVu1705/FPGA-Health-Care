TOPLEVEL := i2c_slave_tb
COCOTB_TEST_MODULES := tests.unit.test_i2c_slave
VERILOG_SOURCES := $(RTL_ROOT)/serial_comm/i2c_slave/i2c_slave.v
VERILOG_SOURCES += $(VERIF_ROOT)/models/i2c_slave_tb.v
