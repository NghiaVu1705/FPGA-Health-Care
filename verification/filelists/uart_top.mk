TOPLEVEL := uart_top
COCOTB_TEST_MODULES := tests.unit.test_uart_top

COMPILE_ARGS += -Puart_top.CLK_FRE=1 -Puart_top.BAUD_RATE=100000

VERILOG_SOURCES := $(RTL_ROOT)/serial_comm/uart/uart_rx.v
VERILOG_SOURCES += $(RTL_ROOT)/serial_comm/uart/uart_tx.v
VERILOG_SOURCES += $(RTL_ROOT)/serial_comm/uart/uart_top.v
