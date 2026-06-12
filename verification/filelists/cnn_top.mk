TOPLEVEL := cnn_top
COCOTB_TEST_MODULES := tests.subsystem.test_cnn_top

VERILOG_SOURCES := $(RTL_ROOT)/healthcare_core/cnn_accelerator/relu_unit.v
VERILOG_SOURCES += $(RTL_ROOT)/healthcare_core/cnn_accelerator/maxpool_unit.v
VERILOG_SOURCES += $(RTL_ROOT)/healthcare_core/cnn_accelerator/global_maxpool_unit.v
VERILOG_SOURCES += $(RTL_ROOT)/healthcare_core/cnn_accelerator/conv2d_engine.v
VERILOG_SOURCES += $(RTL_ROOT)/healthcare_core/cnn_accelerator/fc_layer.v
VERILOG_SOURCES += $(RTL_ROOT)/healthcare_core/cnn_accelerator/cnn_top.v
