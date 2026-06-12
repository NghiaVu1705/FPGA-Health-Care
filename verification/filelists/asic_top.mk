TOPLEVEL := asic_top
COCOTB_TEST_MODULES := tests.integration.test_asic_top

COMPILE_ARGS += -Pasic_top.HAMMING_INIT=\"../rtl/gowin_bsram/hamming_coeff_rom.hex\"
COMPILE_ARGS += -Pasic_top.TWIDDLE_INIT=\"../rtl/gowin_bsram/fft_twiddle_rom.hex\"
COMPILE_ARGS += -Pasic_top.EEG_CNN_INIT=\"../rtl/gowin_bsram/eeg/cnn_weights.hex\"
COMPILE_ARGS += -Pasic_top.ECG_CNN_INIT=\"../rtl/gowin_bsram/ecg/cnn_weights.hex\"
COMPILE_ARGS += -Pasic_top.EMG_CNN_INIT=\"../rtl/gowin_bsram/emg/cnn_weights.hex\"

VERILOG_SOURCES := $(VERIF_ROOT)/../asic/sram_1024x32_model.v
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
VERILOG_SOURCES += $(VERIF_ROOT)/../asic/asic_top.v
