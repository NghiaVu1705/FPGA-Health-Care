TOPLEVEL := top
COCOTB_TEST_MODULES := tests.integration.test_top_modes

COMPILE_ARGS += -DUSE_GOWIN_IP_STUBS -Ptop.ENABLE_FULL_AI_LANES=0 -Ptop.ENABLE_EEG_AI_LANE=0

VERILOG_SOURCES := $(VERIF_ROOT)/models/gowin_ip_models.v
VERILOG_SOURCES += $(RTL_ROOT)/gowin_ip/gowin_fifo_async.v
VERILOG_SOURCES += $(VERIF_ROOT)/models/tmds_pll_stub.v
VERILOG_SOURCES += $(VERIF_ROOT)/models/dvi_tx_stub.v
VERILOG_SOURCES += $(RTL_ROOT)/common/reset_sync.v
VERILOG_SOURCES += $(RTL_ROOT)/serial_comm/uart/uart_rx.v
VERILOG_SOURCES += $(RTL_ROOT)/serial_comm/uart/uart_tx.v
VERILOG_SOURCES += $(RTL_ROOT)/serial_comm/uart/uart_top.v
VERILOG_SOURCES += $(RTL_ROOT)/serial_comm/spi_slave/spi_slave.v
VERILOG_SOURCES += $(RTL_ROOT)/serial_comm/i2c_slave/i2c_slave.v
VERILOG_SOURCES += $(RTL_ROOT)/healthcare_core/threshold/threshold_proc.v
VERILOG_SOURCES += $(RTL_ROOT)/healthcare_core/decision/decision_layer.v
VERILOG_SOURCES += $(RTL_ROOT)/healthcare_core/stft/fft_radix2_64.v
VERILOG_SOURCES += $(RTL_ROOT)/healthcare_core/stft/stft_top.v
VERILOG_SOURCES += $(RTL_ROOT)/healthcare_core/cnn_accelerator/relu_unit.v
VERILOG_SOURCES += $(RTL_ROOT)/healthcare_core/cnn_accelerator/maxpool_unit.v
VERILOG_SOURCES += $(RTL_ROOT)/healthcare_core/cnn_accelerator/global_maxpool_unit.v
VERILOG_SOURCES += $(RTL_ROOT)/healthcare_core/cnn_accelerator/conv2d_engine.v
VERILOG_SOURCES += $(RTL_ROOT)/healthcare_core/cnn_accelerator/fc_layer.v
VERILOG_SOURCES += $(RTL_ROOT)/healthcare_core/cnn_accelerator/cnn_top.v
VERILOG_SOURCES += $(RTL_ROOT)/display/vga_timing.v
VERILOG_SOURCES += $(RTL_ROOT)/display/waveform_display.v
VERILOG_SOURCES += $(RTL_ROOT)/display/osd_overlay.v
VERILOG_SOURCES += $(RTL_ROOT)/display/text_renderer.v
VERILOG_SOURCES += $(RTL_ROOT)/top/top.v
