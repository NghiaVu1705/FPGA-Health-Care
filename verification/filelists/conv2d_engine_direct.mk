TOPLEVEL := conv2d_engine
COCOTB_TEST_MODULES := tests.unit.test_conv2d_engine_direct

VERILOG_SOURCES := $(RTL_ROOT)/healthcare_core/cnn_accelerator/conv2d_engine.v

# Default parameters for direct DW test (overridden by individual cases if needed)
COMPILE_ARGS += -Pconv2d_engine.MODE=\"DW\"
COMPILE_ARGS += -Pconv2d_engine.C_IN=1
COMPILE_ARGS += -Pconv2d_engine.C_OUT=1
COMPILE_ARGS += -Pconv2d_engine.C_OUT_EFF=1
COMPILE_ARGS += -Pconv2d_engine.W_DEPTH=9
COMPILE_ARGS += -Pconv2d_engine.H=8
COMPILE_ARGS += -Pconv2d_engine.W=8
COMPILE_ARGS += -Pconv2d_engine.SHIFT=0
