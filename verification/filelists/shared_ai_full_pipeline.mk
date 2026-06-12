TOPLEVEL := shared_ai_full_pipeline_tb
COCOTB_TEST_MODULES := tests.integration.test_shared_ai_full_pipeline

COMPILE_ARGS += -DCOCOTB_SIM -DUSE_GOWIN_IP_STUBS

VERILOG_SOURCES := $(VERIF_ROOT)/models/gowin_ip_models.v
VERILOG_SOURCES += $(RTL_ROOT)/common/crc32.v
VERILOG_SOURCES += $(RTL_ROOT)/memory/ddr3_burst_writer.v
VERILOG_SOURCES += $(RTL_ROOT)/memory/weight_boot_loader.v
VERILOG_SOURCES += $(RTL_ROOT)/memory/ddr3_weight_prefetcher.v
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
VERILOG_SOURCES += $(RTL_ROOT)/display/vga_timing.v
VERILOG_SOURCES += $(RTL_ROOT)/display/waveform_display.v
VERILOG_SOURCES += $(RTL_ROOT)/display/text_renderer.v
VERILOG_SOURCES += $(RTL_ROOT)/display/osd_overlay.v
VERILOG_SOURCES += $(RTL_ROOT)/system/biomed_shared_ai_system.v
VERILOG_SOURCES += $(VERIF_ROOT)/models/shared_ai_full_pipeline_tb.v
