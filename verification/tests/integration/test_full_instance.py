import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from coverage.functional_coverage import cover


async def reset(dut):
    dut.rst_n.value = 0
    dut.uart_rx_emg.value = 1
    dut.spi_sck.value = 0
    dut.spi_mosi.value = 0
    dut.spi_cs_n.value = 1
    dut.i2c_scl.value = 1
    dut.i2c_sda.value = 1
    dut.case_next_n.value = 1
    dut.hamming_data_eeg_in.value = 0x14
    dut.hamming_data_ecg_in.value = 0x40
    dut.hamming_data_emg_in.value = 0x80
    dut.twiddle_data_eeg_in.value = 0x40000000
    dut.twiddle_data_ecg_in.value = 0x3FBAF9BA
    dut.twiddle_data_emg_in.value = 0x00004000
    dut.cnn_data_eeg_in.value = 0x11
    dut.cnn_data_ecg_in.value = 0x22
    dut.cnn_data_emg_in.value = 0x33
    dut.weight_boot_start.value = 0
    dut.flash_weight_data.value = 0
    dut.flash_weight_valid.value = 0
    dut.ddr_cmd_ready.value = 1
    dut.ddr_wr_data_rdy.value = 1
    for _ in range(8):
        await RisingEdge(dut.sys_clk)
    dut.rst_n.value = 1
    for _ in range(8):
        await RisingEdge(dut.sys_clk)
    for _ in range(8):
        await RisingEdge(dut.pixel_clk)


@cocotb.test()
async def test_full_instance_elaboration_smoke(dut):
    dut.rst_n.value = 0
    dut.uart_rx_emg.value = 1
    dut.spi_sck.value = 0
    dut.spi_mosi.value = 0
    dut.spi_cs_n.value = 1
    dut.i2c_scl.value = 1
    dut.i2c_sda.value = 1
    dut.case_next_n.value = 1
    dut.hamming_data_eeg_in.value = 0x14
    dut.hamming_data_ecg_in.value = 0x40
    dut.hamming_data_emg_in.value = 0x80
    dut.twiddle_data_eeg_in.value = 0x40000000
    dut.twiddle_data_ecg_in.value = 0x3FBAF9BA
    dut.twiddle_data_emg_in.value = 0x00004000
    dut.cnn_data_eeg_in.value = 0x11
    dut.cnn_data_ecg_in.value = 0x22
    dut.cnn_data_emg_in.value = 0x33
    dut.weight_boot_start.value = 0
    dut.flash_weight_data.value = 0
    dut.flash_weight_valid.value = 0
    dut.ddr_cmd_ready.value = 1
    dut.ddr_wr_data_rdy.value = 1
    cocotb.start_soon(Clock(dut.sys_clk, 10, unit="ns").start())
    cocotb.start_soon(Clock(dut.pixel_clk, 13, unit="ns").start())
    await reset(dut)

    assert dut.u_uart.u_rx.rx_data.value.is_resolvable
    assert dut.u_uart.u_tx.tx_busy.value.is_resolvable
    assert dut.u_spi.rx_valid.value.is_resolvable
    assert dut.u_i2c.data_updated.value.is_resolvable
    cover("full_instance.sensor_ingress_tree")

    assert dut.u_weight_boot_loader.busy.value.is_resolvable
    assert dut.flash_weight_ready.value.is_resolvable
    assert dut.ddr_cmd_en.value.is_resolvable
    assert dut.ddr_wr_data_en.value.is_resolvable
    cover("full_instance.weight_stream_tree")

    assert dut.u_stft_eeg.spec_valid.value.is_resolvable
    assert dut.u_stft_ecg.spec_valid.value.is_resolvable
    assert dut.u_stft_emg.spec_valid.value.is_resolvable
    assert dut.u_cnn_eeg.class_valid.value.is_resolvable
    assert dut.u_cnn_ecg.class_valid.value.is_resolvable
    assert dut.u_cnn_emg.class_valid.value.is_resolvable
    cover("full_instance.stft_cnn_tree")

    assert dut.u_hamming_window_helper.windowed_valid.value.is_resolvable
    assert dut.u_magnitude_calc_helper.frame_done.value.is_resolvable
    assert dut.helper_mac_acc.value.is_resolvable
    assert dut.hamming_addr_eeg_out.value.is_resolvable
    assert dut.twiddle_addr_eeg_out.value.is_resolvable
    assert dut.cnn_addr_eeg_out.value.is_resolvable
    assert dut.divided_clk_unused.value.is_resolvable
    cover("full_instance.standalone_helper_tree")

    for _ in range(20):
        await RisingEdge(dut.pixel_clk)
    assert dut.u_vga.de.value.is_resolvable
    assert dut.u_waveform_display.pixel_out.value.is_resolvable
    assert dut.u_osd_overlay.r_out.value.is_resolvable
    assert dut.u_text_renderer_helper._name == "u_text_renderer_helper"
    assert dut.pixel_rgb.value.is_resolvable
    cover("full_instance.display_tree")

    dut.case_next_n.value = 0
    await RisingEdge(dut.sys_clk)
    dut.case_next_n.value = 1
    for _ in range(4):
        await RisingEdge(dut.sys_clk)
    assert dut.final_class.value.is_resolvable
    assert dut.triggered_sensors.value.is_resolvable
    assert dut.confidence.value.is_resolvable
    cover("full_instance.decision_tree")
