TOPLEVEL := cnn_submodules_tb
COCOTB_TEST_MODULES := tests.unit.test_cnn_submodules

VERILOG_SOURCES := $(RTL_ROOT)/healthcare_core/cnn_accelerator/relu_unit.v
VERILOG_SOURCES += $(RTL_ROOT)/healthcare_core/cnn_accelerator/conv2d_engine.v
VERILOG_SOURCES += $(RTL_ROOT)/healthcare_core/cnn_accelerator/maxpool_unit.v
VERILOG_SOURCES += $(RTL_ROOT)/healthcare_core/cnn_accelerator/global_maxpool_unit.v
VERILOG_SOURCES += $(RTL_ROOT)/healthcare_core/cnn_accelerator/fc_layer.v
VERILOG_SOURCES += $(VERIF_ROOT)/models/cnn_submodules_tb.v
