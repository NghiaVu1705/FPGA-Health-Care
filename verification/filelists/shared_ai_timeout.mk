TOPLEVEL := biomed_shared_ai_system
COCOTB_TEST_MODULES := tests.integration.test_shared_ai_timeout

# Parameter override to make the ST_WAIT watchdog tractable in simulation.
COMPILE_ARGS += -Pbiomed_shared_ai_system.CNN_INFER_TIMEOUT=20

VERILOG_SOURCES := $(RTL_ROOT)/memory/ddr3_weight_prefetcher.v
VERILOG_SOURCES += $(RTL_ROOT)/memory/weight_cache_512x8.v
VERILOG_SOURCES += $(RTL_ROOT)/healthcare_core/threshold/threshold_proc.v
VERILOG_SOURCES += $(RTL_ROOT)/healthcare_core/decision/decision_layer.v
VERILOG_SOURCES += $(RTL_ROOT)/healthcare_core/stft/fft_radix2_64.v
VERILOG_SOURCES += $(RTL_ROOT)/healthcare_core/stft/stft_top.v
VERILOG_SOURCES += $(RTL_ROOT)/healthcare_core/cnn_accelerator/mac_unit.v
VERILOG_SOURCES += $(RTL_ROOT)/healthcare_core/cnn_accelerator/relu_unit.v
VERILOG_SOURCES += $(RTL_ROOT)/healthcare_core/cnn_accelerator/maxpool_unit.v
VERILOG_SOURCES += $(RTL_ROOT)/healthcare_core/cnn_accelerator/global_maxpool_unit.v
VERILOG_SOURCES += $(RTL_ROOT)/healthcare_core/cnn_accelerator/conv2d_engine.v
VERILOG_SOURCES += $(RTL_ROOT)/healthcare_core/cnn_accelerator/fc_layer.v
VERILOG_SOURCES += $(RTL_ROOT)/healthcare_core/cnn_accelerator/cnn_top.v
VERILOG_SOURCES += $(RTL_ROOT)/system/biomed_shared_ai_system.v
