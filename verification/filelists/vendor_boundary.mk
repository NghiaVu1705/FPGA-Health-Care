TOPLEVEL := vendor_boundary_tb
COCOTB_TEST_MODULES := tests.integration.test_vendor_boundary

COMPILE_ARGS += -DUSE_GOWIN_IP_STUBS

VERILOG_SOURCES := $(VERIF_ROOT)/models/gowin_ip_models.v
VERILOG_SOURCES += $(RTL_ROOT)/gowin_ip/gowin_fifo_async.v
VERILOG_SOURCES += $(VERIF_ROOT)/models/tmds_pll_stub.v
VERILOG_SOURCES += $(VERIF_ROOT)/models/dvi_tx_stub.v
VERILOG_SOURCES += $(VERIF_ROOT)/models/vendor_boundary_tb.v
