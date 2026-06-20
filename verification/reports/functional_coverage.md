# Functional Coverage Report

- Total bins: 137
- Covered bins: 137
- Coverage: 100.00%
- Missing bins: 0
- Unknown hits: 0

| Status | Bin | DUT | Owner | Description | Hits |
| --- | --- | --- | --- | --- | ---: |
| PASS | `threshold.spo2_normal` | `threshold_proc` | `tests.unit.test_threshold_proc` | SpO2 normal boundary and interior | 20 |
| PASS | `threshold.spo2_abnormal` | `threshold_proc` | `tests.unit.test_threshold_proc` | SpO2 abnormal boundary and interior | 4 |
| PASS | `threshold.spo2_critical` | `threshold_proc` | `tests.unit.test_threshold_proc` | SpO2 critical boundary and interior | 2 |
| PASS | `threshold.temp_normal` | `threshold_proc` | `tests.unit.test_threshold_proc` | Temperature normal range | 14 |
| PASS | `threshold.temp_abnormal_low` | `threshold_proc` | `tests.unit.test_threshold_proc` | Temperature abnormal low range | 4 |
| PASS | `threshold.temp_abnormal_high` | `threshold_proc` | `tests.unit.test_threshold_proc` | Temperature abnormal high range | 4 |
| PASS | `threshold.temp_critical_low` | `threshold_proc` | `tests.unit.test_threshold_proc` | Temperature critical low range | 2 |
| PASS | `threshold.temp_critical_high` | `threshold_proc` | `tests.unit.test_threshold_proc` | Temperature critical high range | 2 |
| PASS | `threshold.random_constrained` | `threshold_proc` | `tests.unit.test_threshold_proc` | Constrained random threshold samples | 2 |
| PASS | `decision.class_0` | `decision_layer` | `tests.unit.test_decision_layer` | Normal output class | 2 |
| PASS | `decision.class_1` | `decision_layer` | `tests.unit.test_decision_layer` | Abnormal output class | 4 |
| PASS | `decision.class_2` | `decision_layer` | `tests.unit.test_decision_layer` | Critical output class | 2 |
| PASS | `decision.class_3_fail_safe` | `decision_layer` | `tests.unit.test_decision_layer` | Invalid 2'b11 input is fail-safe critical | 2 |
| PASS | `decision.tie_break_high_severity` | `decision_layer` | `tests.unit.test_decision_layer` | Tie-break selects higher severity | 2 |
| PASS | `decision.sliding_window` | `decision_layer` | `tests.unit.test_decision_layer` | Five-sample sliding window updates class | 4 |
| PASS | `decision.conf_low` | `decision_layer` | `tests.unit.test_decision_layer` | Low confidence count | 2 |
| PASS | `decision.conf_medium` | `decision_layer` | `tests.unit.test_decision_layer` | Medium confidence count | 2 |
| PASS | `decision.conf_high` | `decision_layer` | `tests.unit.test_decision_layer` | High confidence count | 6 |
| PASS | `decision.trigger_eeg` | `decision_layer` | `tests.unit.test_decision_layer` | EEG trigger bit | 6 |
| PASS | `decision.trigger_ecg` | `decision_layer` | `tests.unit.test_decision_layer` | ECG trigger bit | 2 |
| PASS | `decision.trigger_emg` | `decision_layer` | `tests.unit.test_decision_layer` | EMG trigger bit | 2 |
| PASS | `decision.trigger_spo2` | `decision_layer` | `tests.unit.test_decision_layer` | SpO2 trigger bit | 2 |
| PASS | `decision.trigger_temp` | `decision_layer` | `tests.unit.test_decision_layer` | Temperature trigger bit | 2 |
| PASS | `stft.zero_input` | `stft_top` | `tests.subsystem.test_stft_top` | Zero input frame behavior | 1 |
| PASS | `stft.sine_bin` | `stft_top` | `tests.subsystem.test_stft_top` | Sine wave peak bin | 1 |
| PASS | `stft.amplitude_sweep` | `stft_top` | `tests.subsystem.test_stft_top` | Sine amplitude sweep model coverage | 1 |
| PASS | `stft.backpressure` | `stft_top` | `tests.subsystem.test_stft_top` | spec_ready backpressure boundary | 1 |
| PASS | `stft.reset_mid_frame` | `stft_top` | `tests.subsystem.test_stft_top` | Reset during input frame | 1 |
| PASS | `stft.timeout_guard` | `stft_top` | `tests.subsystem.test_stft_top` | Output collection timeout guard | 1 |
| PASS | `stft.mse_golden` | `stft_top` | `tests.subsystem.test_stft_top` | MSE against scipy STFT golden model | 1 |
| PASS | `cnn.rom_eeg` | `cnn_top` | `tests.subsystem.test_cnn_top` | EEG ROM image load | 2 |
| PASS | `cnn.rom_ecg` | `cnn_top` | `tests.subsystem.test_cnn_top` | ECG ROM image availability | 2 |
| PASS | `cnn.rom_emg` | `cnn_top` | `tests.subsystem.test_cnn_top` | EMG ROM image availability | 2 |
| PASS | `cnn.first_byte_start` | `cnn_top` | `tests.subsystem.test_cnn_top` | First byte spec_start behavior | 2 |
| PASS | `cnn.valid_gap` | `cnn_top` | `tests.subsystem.test_cnn_top` | Input valid gap tolerance | 2 |
| PASS | `cnn.numpy_match` | `cnn_top` | `tests.subsystem.test_cnn_top` | RTL class equals numpy Tiny CNN | 2 |
| PASS | `uart.valid_frame` | `uart_top` | `tests.unit.test_uart_top` | Valid EMG UART frame accepted | 1 |
| PASS | `uart.bad_checksum` | `uart_top` | `tests.unit.test_uart_top` | Bad checksum frame rejected | 1 |
| PASS | `uart.resync_garbage` | `uart_top` | `tests.unit.test_uart_top` | Garbage bytes before header are ignored | 1 |
| PASS | `uart.back_to_back` | `uart_top` | `tests.unit.test_uart_top` | Back-to-back UART frames | 1 |
| PASS | `uart.debug_ready_busy` | `uart_top` | `tests.unit.test_uart_top` | Debug TX ready/busy handshake | 1 |
| PASS | `spi.eeg_channel` | `spi_slave` | `tests.unit.test_spi_slave` | SPI EEG channel decode | 2 |
| PASS | `spi.ecg_channel` | `spi_slave` | `tests.unit.test_spi_slave` | SPI ECG channel decode | 2 |
| PASS | `spi.adc_min` | `spi_slave` | `tests.unit.test_spi_slave` | ADC minimum sample decode | 2 |
| PASS | `spi.adc_mid` | `spi_slave` | `tests.unit.test_spi_slave` | ADC mid-scale sample decode | 2 |
| PASS | `spi.adc_max` | `spi_slave` | `tests.unit.test_spi_slave` | ADC maximum sample decode | 2 |
| PASS | `spi.cs_abort` | `spi_slave` | `tests.unit.test_spi_slave` | CS abort/recovery | 2 |
| PASS | `spi.back_to_back` | `spi_slave` | `tests.unit.test_spi_slave` | Back-to-back SPI frames | 2 |
| PASS | `i2c.reset_defaults` | `i2c_slave` | `tests.unit.test_i2c_slave` | I2C reset default vitals | 1 |
| PASS | `i2c.write_spo2` | `i2c_slave` | `tests.unit.test_i2c_slave` | Write SpO2 register 0x00 | 1 |
| PASS | `i2c.write_temp` | `i2c_slave` | `tests.unit.test_i2c_slave` | Write temperature register 0x01 | 1 |
| PASS | `i2c.invalid_address` | `i2c_slave` | `tests.unit.test_i2c_slave` | Invalid I2C address ignored | 1 |
| PASS | `i2c.invalid_register` | `i2c_slave` | `tests.unit.test_i2c_slave` | Invalid I2C register ignored | 1 |
| PASS | `i2c.repeated_start_stop` | `i2c_slave` | `tests.unit.test_i2c_slave` | Repeated start/stop recovery | 1 |
| PASS | `i2c.ack_held_9th_clock` | `i2c_slave` | `tests.unit.test_i2c_slave` | Slave holds ACK (SDA low) through the full 9th SCL pulse so a real master reads ACK | 1 |
| PASS | `display.vga_de` | `vga_timing` | `tests.unit.test_vga_timing` | VGA active display enable region | 1 |
| PASS | `display.vga_hs_vs` | `vga_timing` | `tests.unit.test_vga_timing` | VGA sync pulse behavior | 1 |
| PASS | `display.wave_eeg` | `waveform_display` | `tests.unit.test_waveform_display` | EEG waveform color region | 2 |
| PASS | `display.wave_ecg` | `waveform_display` | `tests.unit.test_waveform_display` | ECG waveform color region | 2 |
| PASS | `display.wave_emg` | `waveform_display` | `tests.unit.test_waveform_display` | EMG waveform color region | 2 |
| PASS | `display.wave_grid` | `waveform_display` | `tests.unit.test_waveform_display` | Waveform grid region | 2 |
| PASS | `display.wave_bg` | `waveform_display` | `tests.unit.test_waveform_display` | Waveform background region | 2 |
| PASS | `display.osd_class_regions` | `osd_overlay` | `tests.unit.test_osd_overlay` | OSD class severity regions | 2 |
| PASS | `display.osd_sensor_regions` | `osd_overlay` | `tests.unit.test_osd_overlay` | OSD sensor icon regions | 2 |
| PASS | `display.osd_conf_vitals` | `osd_overlay` | `tests.unit.test_osd_overlay` | OSD confidence and vitals regions | 2 |
| PASS | `display.osd_icon_content` | `osd_overlay` | `tests.unit.test_osd_overlay` | OSD status icon pixel follows the icon ROM bitmap content | 2 |
| PASS | `display.text_cell_on_off` | `text_renderer` | `tests.unit.test_text_renderer` | Text renderer cell on/off pixels | 2 |
| PASS | `display.text_font_content` | `text_renderer` | `tests.unit.test_text_renderer` | Glyph 'A' renders pixel-exact from the real font8x16.hex bitmap | 2 |
| PASS | `cnn_sub.relu_clip` | `cnn_submodules` | `tests.unit.test_cnn_submodules` | ReLU negative/positive/saturating behavior | 2 |
| PASS | `cnn_sub.conv_dw` | `cnn_submodules` | `tests.unit.test_cnn_submodules` | Depthwise conv smoke | 2 |
| PASS | `cnn_sub.conv_pw` | `cnn_submodules` | `tests.unit.test_cnn_submodules` | Pointwise conv smoke | 2 |
| PASS | `cnn_sub.maxpool` | `cnn_submodules` | `tests.unit.test_cnn_submodules` | 2x2 maxpool smoke | 2 |
| PASS | `cnn_sub.global_maxpool` | `cnn_submodules` | `tests.unit.test_cnn_submodules` | Global maxpool smoke | 2 |
| PASS | `cnn_sub.fc_argmax` | `cnn_submodules` | `tests.unit.test_cnn_submodules` | FC argmax smoke | 2 |
| PASS | `fft.impulse` | `fft_radix2_64` | `tests.unit.test_fft_radix2_64` | FFT impulse response | 2 |
| PASS | `fft.dc` | `fft_radix2_64` | `tests.unit.test_fft_radix2_64` | FFT DC response | 2 |
| PASS | `fft.sine_bin` | `fft_radix2_64` | `tests.unit.test_fft_radix2_64` | FFT sine-bin response | 2 |
| PASS | `fft.reset` | `fft_radix2_64` | `tests.unit.test_fft_radix2_64` | FFT reset behavior | 2 |
| PASS | `full_instance.sensor_ingress_tree` | `full_instance` | `tests.integration.test_full_instance` | Full system instantiates UART/SPI/I2C ingress tree | 1 |
| PASS | `full_instance.weight_stream_tree` | `full_instance` | `tests.integration.test_full_instance` | Full system instantiates flash weight loader and DDR3 write boundary | 1 |
| PASS | `full_instance.stft_cnn_tree` | `full_instance` | `tests.integration.test_full_instance` | Full system instantiates three STFT and CNN lanes | 1 |
| PASS | `full_instance.standalone_helper_tree` | `full_instance` | `tests.integration.test_full_instance` | Full system instantiates standalone helper RTL blocks | 1 |
| PASS | `full_instance.display_tree` | `full_instance` | `tests.integration.test_full_instance` | Full system instantiates VGA waveform OSD and text display tree | 1 |
| PASS | `full_instance.decision_tree` | `full_instance` | `tests.integration.test_full_instance` | Full system instantiates threshold and decision output tree | 1 |
| PASS | `top.lite_elaboration` | `top_lite` | `tests.integration.test_top_modes` | FPGA top lite mode elaborates/runs | 1 |
| PASS | `top.sensor_boundary` | `top_lite` | `tests.integration.test_top_modes` | Top-level sensor boundary pins driven | 1 |
| PASS | `top.dvi_boundary` | `top_lite` | `tests.integration.test_top_modes` | Top-level DVI boundary toggles | 1 |
| PASS | `top.full_elaboration` | `top_full_lint` | `tests.integration.test_top_modes` | FPGA top full mode elaborates for lint/smoke | 1 |
| PASS | `weight_image.header_parse` | `weight_boot_loader` | `tests.memory.test_weight_boot_loader` | Packed weight image header parsed and validated | 2 |
| PASS | `weight_image.entry_table_parse` | `weight_boot_loader` | `tests.memory.test_weight_boot_loader` | Weight image entry table parsed | 18 |
| PASS | `weight_image.copy_to_ddr` | `weight_boot_loader` | `tests.memory.test_weight_boot_loader` | All image payloads copied into expected DDR3 addresses | 2 |
| PASS | `weight_image.payload_alignment` | `weight_boot_loader` | `tests.memory.test_weight_boot_loader` | 256-byte aligned payload gaps are skipped correctly | 2 |
| PASS | `flash_loader.copy_to_ddr` | `weight_boot_loader` | `tests.memory.test_weight_boot_loader` | Flash byte stream drives DDR3 copy path | 2 |
| PASS | `ddr3_adapter.write_burst` | `weight_boot_loader` | `tests.memory.test_weight_boot_loader` | DDR3 native write command/data burst emitted | 116 |
| PASS | `ddr3_adapter.write_partial_burst` | `weight_boot_loader` | `tests.memory.test_weight_boot_loader` | Final partial DDR3 beat uses byte mask | 2 |
| PASS | `shared_ai.ddr_prefetch_commands` | `ddr3_weight_prefetcher` | `tests.memory.test_ddr3_weight_prefetcher` | DDR3 read commands emitted for one 512-byte weight tile | 2 |
| PASS | `shared_ai.ddr_prefetch_cache_fill` | `ddr3_weight_prefetcher` | `tests.memory.test_ddr3_weight_prefetcher` | DDR3 read data fills all 512 local cache bytes | 2 |
| PASS | `shared_ai.weight_prefetch` | `shared_ai_system` | `tests.integration.test_shared_ai_system` | Shared AI system prefetches channel weights from DDR3 | 2 |
| PASS | `shared_ai.cache_to_cnn` | `shared_ai_system` | `tests.integration.test_shared_ai_system` | Shared CNN loads weights through the local cache read port | 2 |
| PASS | `shared_ai.channel_advance` | `shared_ai_system` | `tests.integration.test_shared_ai_system` | Scheduler advances from EEG to ECG after one inference | 2 |
| PASS | `shared_ai.decision_update` | `shared_ai_system` | `tests.integration.test_shared_ai_system` | Shared AI classification updates the decision layer outputs | 2 |
| PASS | `system.weight_boot_to_ddr` | `shared_ai_full_pipeline` | `tests.integration.test_shared_ai_full_pipeline` | Packed weight image is loaded through weight_boot_loader into DDR before inference | 2 |
| PASS | `system.ddr_weights_used` | `shared_ai_full_pipeline` | `tests.integration.test_shared_ai_full_pipeline` | Shared AI prefetches CNN weights from the loaded DDR image | 6 |
| PASS | `system.replay_expected_class` | `shared_ai_full_pipeline` | `tests.integration.test_shared_ai_full_pipeline` | Replay EEG/ECG/EMG windows produce expected 6-class CNN outputs | 6 |
| PASS | `system.decision_to_osd` | `shared_ai_full_pipeline` | `tests.integration.test_shared_ai_full_pipeline` | Full replay classification updates decision output consumed by OSD | 2 |
| PASS | `system.real_top_weight_boot` | `top_shared_ai_smoke` | `tests.integration.test_top_shared_ai_smoke` | Real top_shared_ai boot FSM streams registered weight_image_rom through the CRC loader (weight_load_done, no error) | 1 |
| PASS | `system.real_top_ddr_payload` | `top_shared_ai_smoke` | `tests.integration.test_top_shared_ai_smoke` | Real top boot writes each per-channel weight image to its DDR base (0/4096/8192) | 1 |
| PASS | `system.real_top_ai_prefetch` | `top_shared_ai_smoke` | `tests.integration.test_top_shared_ai_smoke` | AI core released after boot and prefetches boot-loaded weights from DDR (weights_ready) | 1 |
| PASS | `system.real_top_tmds` | `top_shared_ai_smoke` | `tests.integration.test_top_shared_ai_smoke` | Real top display path produces resolvable TMDS outputs | 1 |
| PASS | `system.boot_error` | `top_shared_ai_smoke` | `tests.integration.test_top_shared_ai_smoke` | Corrupt weight image -> weight_load_error, boot never reaches RUN | 1 |
| PASS | `system.replay_bypass_on_boot_error` | `top_shared_ai_smoke` | `tests.integration.test_top_shared_ai_smoke` | Replay bypass releases the AI core even when boot failed | 1 |
| PASS | `replay.case_window` | `top_shared_ai_smoke` | `tests.integration.test_top_shared_ai_smoke` | AB13 replay_case selects the correct per-case ROM window base | 3 |
| PASS | `replay.case_vitals` | `top_shared_ai_smoke` | `tests.integration.test_top_shared_ai_smoke` | Per-case simulated SpO2/Temp vitals for Normal/Abnormal/Critical | 3 |
| PASS | `replay.live_passthrough` | `top_shared_ai_smoke` | `tests.integration.test_top_shared_ai_smoke` | replay_case 0 = live: vitals pass through, replay off | 1 |
| PASS | `replay.button_press` | `top_shared_ai_smoke` | `tests.integration.test_top_shared_ai_smoke` | Debounced AB13 press advances replay_case and enters replay mode | 1 |
| PASS | `shared_ai.ddr_prefetch_timeout` | `ddr3_weight_prefetcher` | `tests.memory.test_ddr3_weight_prefetcher` | DDR3 read never returns -> prefetcher watchdog raises error (no hang) | 2 |
| PASS | `weight_cache.readback` | `weight_cache` | `tests.unit.test_weight_cache` | Registered (1-cycle) weight cache write/read-back across the address space | 2 |
| PASS | `weight_cache.write_read` | `weight_cache` | `tests.unit.test_weight_cache` | Write-then-read of a fresh address returns the new byte (no stale read) | 2 |
| PASS | `severity.eeg_map` | `severity_mapper` | `tests.unit.test_severity_mapper` | EEG 6-class -> 3-level severity map (Critical class 2) | 12 |
| PASS | `severity.ecg_map` | `severity_mapper` | `tests.unit.test_severity_mapper` | ECG 6-class -> 3-level severity map (Critical class 4) | 12 |
| PASS | `severity.emg_map` | `severity_mapper` | `tests.unit.test_severity_mapper` | EMG 6-class -> 3-level severity map (Critical class 3) | 12 |
| PASS | `severity.level_reached` | `severity_mapper` | `tests.unit.test_severity_mapper` | All three severity levels (Normal/Abnormal/Critical) reachable | 6 |
| PASS | `vendor.bsram_boundary` | `vendor_boundary` | `tests.integration.test_vendor_boundary` | Gowin BSRAM wrapper boundary | 1 |
| PASS | `vendor.fifo_boundary` | `vendor_boundary` | `tests.integration.test_vendor_boundary` | Gowin FIFO wrapper boundary | 1 |
| PASS | `vendor.tmds_boundary` | `vendor_boundary` | `tests.integration.test_vendor_boundary` | TMDS PLL boundary | 1 |
| PASS | `vendor.dvi_boundary` | `vendor_boundary` | `tests.integration.test_vendor_boundary` | DVI TX boundary | 1 |
| PASS | `weight_image.crc_pass` | `weight_boot_loader` | `tests.memory.test_weight_boot_loader_crc` | Payload CRC32 matches manifest | 1 |
| PASS | `weight_image.crc_fail` | `weight_boot_loader` | `tests.memory.test_weight_boot_loader_crc` | Payload CRC32 mismatch raises crc_error | 1 |
| PASS | `conv2d.zero_input` | `conv2d_engine` | `tests.unit.test_conv2d_engine_direct` | DW with all-zero input yields all-bias output | 1 |
| PASS | `conv2d.impulse` | `conv2d_engine` | `tests.unit.test_conv2d_engine_direct` | DW with single non-zero pixel yields kernel-shaped response | 1 |
| PASS | `conv2d.random` | `conv2d_engine` | `tests.unit.test_conv2d_engine_direct` | DW with random inputs matches numpy golden | 1 |
| PASS | `conv2d.saturation` | `conv2d_engine` | `tests.unit.test_conv2d_engine_direct` | DW saturation clip16 boundary (>+127 and <-127) | 1 |
| PASS | `conv2d.pw_multichannel` | `conv2d_engine` | `tests.unit.test_conv2d_engine_direct` | PW with multiple input channels matches golden | 1 |
| PASS | `conv2d.frame_restart` | `conv2d_engine` | `tests.unit.test_conv2d_engine_direct` | Two consecutive frames separated by frame_start | 1 |
| PASS | `shared_ai.cnn_timeout` | `biomed_shared_ai_system` | `tests.integration.test_shared_ai_system` | ST_WAIT watchdog asserts cnn_timeout_error and recovers (sim-only) | 1 |
| PASS | `cdc.bus_handshake_atomic` | `cdc_bus_handshake` | `tests.unit.test_cdc_bus_handshake` | cdc_bus_handshake transfers multi-bit src→dst atomically per src_update pulse | 1 |
| PASS | `cdc.bus_handshake_reset` | `cdc_bus_handshake` | `tests.unit.test_cdc_bus_handshake` | cdc_bus_handshake holds dst_data=0 under reset | 1 |
