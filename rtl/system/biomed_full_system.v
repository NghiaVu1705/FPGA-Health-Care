// biomed_full_system.v - wrapper tích hợp đầy đủ, trung lập công nghệ.
//
// Wrapper này cố ý khởi tạo mọi khối RTL của dự án
// để kiểm chứng có thể chứng minh toàn bộ kiến trúc elaborate được như một hệ thống. Nó
// không phải lớp vỏ chế độ fit FPGA; tổng hợp Gowin nên tiếp tục dùng
// gowin_fpga/src/top.v cho việc bring-up cho đến khi các bộ đệm STFT/CNN được làm lại.
module biomed_full_system (
    input                  sys_clk,
    input                  pixel_clk,
    input                  rst_n,

    input                  uart_rx_emg,
    output                 uart_tx_debug,

    input                  spi_sck,
    input                  spi_mosi,
    input                  spi_cs_n,

    input                  i2c_scl,
    inout                  i2c_sda,

    input                  case_next_n,

    output     [5:0]       hamming_addr_eeg_out,
    output     [5:0]       hamming_addr_ecg_out,
    output     [5:0]       hamming_addr_emg_out,
    input      [7:0]       hamming_data_eeg_in,
    input      [7:0]       hamming_data_ecg_in,
    input      [7:0]       hamming_data_emg_in,

    output     [4:0]       twiddle_addr_eeg_out,
    output     [4:0]       twiddle_addr_ecg_out,
    output     [4:0]       twiddle_addr_emg_out,
    input      [31:0]      twiddle_data_eeg_in,
    input      [31:0]      twiddle_data_ecg_in,
    input      [31:0]      twiddle_data_emg_in,

    output     [8:0]       cnn_addr_eeg_out,
    output     [8:0]       cnn_addr_ecg_out,
    output     [8:0]       cnn_addr_emg_out,
    input      [7:0]       cnn_data_eeg_in,
    input      [7:0]       cnn_data_ecg_in,
    input      [7:0]       cnn_data_emg_in,

    input                  weight_boot_start,
    input      [7:0]       flash_weight_data,
    input                  flash_weight_valid,
    output                 flash_weight_ready,
    output                 weight_boot_busy,
    output                 weight_boot_done,
    output                 weight_boot_error,

    input                  ddr_cmd_ready,
    output     [2:0]       ddr_cmd,
    output                 ddr_cmd_en,
    output     [28:0]      ddr_addr,
    input                  ddr_wr_data_rdy,
    output     [255:0]     ddr_wr_data,
    output                 ddr_wr_data_en,
    output                 ddr_wr_data_end,
    output     [31:0]      ddr_wr_data_mask,

    output [23:0]          pixel_rgb,
    output [1:0]           final_class,
    output [4:0]           triggered_sensors,
    output [1:0]           confidence
);

wire sys_rst_n;
wire pixel_rst_n;

reset_sync u_reset_sync_sys (
    .clk        (sys_clk),
    .rst_async_n(rst_n),
    .rst_sync_n (sys_rst_n)
);

reset_sync u_reset_sync_pixel (
    .clk        (pixel_clk),
    .rst_async_n(rst_n),
    .rst_sync_n (pixel_rst_n)
);

wire divided_clk_unused;

clock_divider #(.DIV(4)) u_clock_divider (
    .clk_in (sys_clk),
    .rst_n  (sys_rst_n),
    .clk_out(divided_clk_unused)
);

// ---------------------------------------------------------------------------
// Thu nhận tín hiệu cảm biến
// ---------------------------------------------------------------------------
wire [15:0] emg_sample;
wire        emg_valid;
// Các wire/reg giao diện FSM của bộ phát UART gỡ lỗi
reg [7:0] tx_data_r;
reg       tx_valid_r;
wire      tx_ready_w;

uart_top #(
    .CLK_FRE  (50),          // phải khớp sys_clk từ gowin_pll_sys (50 MHz)
    .BAUD_RATE(115200)
) u_uart (
    .sys_clk   (sys_clk),
    .rst_n     (sys_rst_n),
    .uart_rx   (uart_rx_emg),
    .uart_tx   (uart_tx_debug),
    .emg_sample(emg_sample),
    .emg_valid (emg_valid),
    .dbg_data  (tx_data_r),
    .dbg_valid (tx_valid_r),
    .dbg_ready (tx_ready_w)
);

wire [15:0] spi_sample;
wire        spi_valid;
wire [1:0]  spi_channel;

spi_slave u_spi (
    .sys_clk  (sys_clk),
    .rst_n    (sys_rst_n),
    .spi_sck  (spi_sck),
    .spi_mosi (spi_mosi),
    .spi_cs_n (spi_cs_n),
    .rx_data  (spi_sample),
    .rx_valid (spi_valid),
    .channel  (spi_channel)
);

wire [7:0] spo2_raw;
wire [7:0] temp_raw;
wire       vitals_updated;

i2c_slave #(.I2C_ADDR(7'h48)) u_i2c (
    .sys_clk     (sys_clk),
    .rst_n       (sys_rst_n),
    .scl         (i2c_scl),
    .sda         (i2c_sda),
    .spo2_raw    (spo2_raw),
    .temp_raw    (temp_raw),
    .data_updated(vitals_updated)
);

wire [15:0] eeg_sample = spi_sample;
wire [15:0] ecg_sample = spi_sample;
wire        eeg_valid  = spi_valid && (spi_channel == 2'd0);
wire        ecg_valid  = spi_valid && (spi_channel == 2'd1);

// ---------------------------------------------------------------------------
// Các làn STFT
// ---------------------------------------------------------------------------
wire [5:0]  hamming_addr_eeg, hamming_addr_ecg, hamming_addr_emg;
wire [4:0]  twiddle_addr_eeg, twiddle_addr_ecg, twiddle_addr_emg;
wire [7:0]  hamming_data_eeg = hamming_data_eeg_in;
wire [7:0]  hamming_data_ecg = hamming_data_ecg_in;
wire [7:0]  hamming_data_emg = hamming_data_emg_in;
wire [31:0] twiddle_data_eeg = twiddle_data_eeg_in;
wire [31:0] twiddle_data_ecg = twiddle_data_ecg_in;
wire [31:0] twiddle_data_emg = twiddle_data_emg_in;

assign hamming_addr_eeg_out = hamming_addr_eeg;
assign hamming_addr_ecg_out = hamming_addr_ecg;
assign hamming_addr_emg_out = hamming_addr_emg;
assign twiddle_addr_eeg_out = twiddle_addr_eeg;
assign twiddle_addr_ecg_out = twiddle_addr_ecg;
assign twiddle_addr_emg_out = twiddle_addr_emg;

wire [7:0] spec_eeg, spec_ecg, spec_emg;
wire       spec_eeg_valid, spec_ecg_valid, spec_emg_valid;

stft_top u_stft_eeg (
    .sys_clk(sys_clk), .rst_n(sys_rst_n),
    .sample_in(eeg_sample), .sample_valid(eeg_valid),
    .spec_out(spec_eeg), .spec_valid(spec_eeg_valid), .spec_ready(1'b1),
    .hamming_rom_addr(hamming_addr_eeg), .hamming_rom_data(hamming_data_eeg),
    .twiddle_rom_addr(twiddle_addr_eeg), .twiddle_rom_data(twiddle_data_eeg)
);

stft_top u_stft_ecg (
    .sys_clk(sys_clk), .rst_n(sys_rst_n),
    .sample_in(ecg_sample), .sample_valid(ecg_valid),
    .spec_out(spec_ecg), .spec_valid(spec_ecg_valid), .spec_ready(1'b1),
    .hamming_rom_addr(hamming_addr_ecg), .hamming_rom_data(hamming_data_ecg),
    .twiddle_rom_addr(twiddle_addr_ecg), .twiddle_rom_data(twiddle_data_ecg)
);

stft_top u_stft_emg (
    .sys_clk(sys_clk), .rst_n(sys_rst_n),
    .sample_in(emg_sample), .sample_valid(emg_valid),
    .spec_out(spec_emg), .spec_valid(spec_emg_valid), .spec_ready(1'b1),
    .hamming_rom_addr(hamming_addr_emg), .hamming_rom_data(hamming_data_emg),
    .twiddle_rom_addr(twiddle_addr_emg), .twiddle_rom_data(twiddle_data_emg)
);

reg spec_eeg_valid_d;
reg spec_ecg_valid_d;
reg spec_emg_valid_d;

always @(posedge sys_clk or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
        spec_eeg_valid_d <= 1'b0;
        spec_ecg_valid_d <= 1'b0;
        spec_emg_valid_d <= 1'b0;
    end else begin
        spec_eeg_valid_d <= spec_eeg_valid;
        spec_ecg_valid_d <= spec_ecg_valid;
        spec_emg_valid_d <= spec_emg_valid;
    end
end

wire spec_eeg_start = spec_eeg_valid & ~spec_eeg_valid_d;
wire spec_ecg_start = spec_ecg_valid & ~spec_ecg_valid_d;
wire spec_emg_start = spec_emg_valid & ~spec_emg_valid_d;

// Các module phụ trợ STFT độc lập được giữ khởi tạo để elaborate đầy đủ
// kiến trúc, vì stft_top hiện triển khai các bước này nội tuyến.
wire signed [15:0] helper_windowed;
wire               helper_windowed_valid;
wire [5:0]         helper_hamming_addr;

hamming_window u_hamming_window_helper (
    .sys_clk       (sys_clk),
    .rst_n         (sys_rst_n),
    .sample_in     (eeg_sample),
    .sample_valid  (eeg_valid),
    .frame_start   (eeg_valid),
    .windowed_out  (helper_windowed),
    .windowed_valid(helper_windowed_valid),
    .rom_addr_out  (helper_hamming_addr),
    .rom_data      (hamming_data_eeg)
);

wire [255:0] helper_mag;
wire         helper_mag_done;
wire signed [31:0] helper_mag_re = {{16{eeg_sample[15]}}, eeg_sample};
wire signed [31:0] helper_mag_im = {{16{ecg_sample[15]}}, ecg_sample};

magnitude_calc u_magnitude_calc_helper (
    .sys_clk    (sys_clk),
    .rst_n      (sys_rst_n),
    .re_in      (helper_mag_re),
    .im_in      (helper_mag_im),
    .bin_valid  (eeg_valid | ecg_valid),
    .frame_start(eeg_valid),
    .mag_out    (helper_mag),
    .frame_done (helper_mag_done)
);

// ---------------------------------------------------------------------------
// Các làn CNN
// ---------------------------------------------------------------------------
wire [8:0] cnn_addr_eeg, cnn_addr_ecg, cnn_addr_emg;
wire [1:0] cnn_eeg_class, cnn_ecg_class, cnn_emg_class;
wire       cnn_eeg_valid, cnn_ecg_valid, cnn_emg_valid;

assign cnn_addr_eeg_out = cnn_addr_eeg;
assign cnn_addr_ecg_out = cnn_addr_ecg;
assign cnn_addr_emg_out = cnn_addr_emg;

cnn_top u_cnn_eeg (
    .sys_clk(sys_clk), .rst_n(sys_rst_n),
    .spec_in(spec_eeg), .spec_valid(spec_eeg_valid), .spec_start(spec_eeg_start),
    .class_out(cnn_eeg_class), .class_valid(cnn_eeg_valid),
    .bsram_addr(cnn_addr_eeg), .bsram_data(cnn_data_eeg_in)
);

cnn_top u_cnn_ecg (
    .sys_clk(sys_clk), .rst_n(sys_rst_n),
    .spec_in(spec_ecg), .spec_valid(spec_ecg_valid), .spec_start(spec_ecg_start),
    .class_out(cnn_ecg_class), .class_valid(cnn_ecg_valid),
    .bsram_addr(cnn_addr_ecg), .bsram_data(cnn_data_ecg_in)
);

cnn_top u_cnn_emg (
    .sys_clk(sys_clk), .rst_n(sys_rst_n),
    .spec_in(spec_emg), .spec_valid(spec_emg_valid), .spec_start(spec_emg_start),
    .class_out(cnn_emg_class), .class_valid(cnn_emg_valid),
    .bsram_addr(cnn_addr_emg), .bsram_data(cnn_data_emg_in)
);

wire signed [31:0] helper_mac_acc;
wire signed [31:0] helper_mac_acc_in = {24'd0, temp_raw};

mac_unit u_mac_unit_helper (
    .weight (cnn_data_eeg_in),
    .act    (spo2_raw),
    .acc_in (helper_mac_acc_in),
    .acc_out(helper_mac_acc)
);

// ---------------------------------------------------------------------------
// Ngưỡng và hợp nhất quyết định
// ---------------------------------------------------------------------------
(* syn_keep = 1 *) wire [1:0] spo2_class;
(* syn_keep = 1 *) wire [1:0] temp_class;

(* syn_noprune = 1 *) threshold_proc u_threshold (
    .spo2_raw  (spo2_raw),
    .temp_raw  (temp_raw),
    .spo2_class(spo2_class),
    .temp_class(temp_class)
);

wire classes_pulse = cnn_eeg_valid | cnn_ecg_valid | cnn_emg_valid |
                     vitals_updated | ~case_next_n;

decision_layer u_decision (
    .sys_clk          (sys_clk),
    .rst_n            (sys_rst_n),
    .eeg_class        (cnn_eeg_class),
    .ecg_class        (cnn_ecg_class),
    .emg_class        (cnn_emg_class),
    .spo2_class       (spo2_class),
    .temp_class       (temp_class),
    .classes_valid    (classes_pulse),
    .class_out        (final_class),
    .triggered_sensors(triggered_sensors),
    .confidence       (confidence)
);

// Bus trạng thái và FSM truyền UART gỡ lỗi
reg [24:0] status_bus_sys;
reg        status_toggle_sys;

always @(posedge sys_clk or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
        status_bus_sys    <= {2'd0, 5'd0, 2'd0, 8'd98, 8'd72};
        status_toggle_sys <= 1'b0;
    end else if (classes_pulse || vitals_updated) begin
        status_bus_sys    <= {final_class, triggered_sensors, confidence, spo2_raw, temp_raw};
        status_toggle_sys <= ~status_toggle_sys;
    end
end

reg [2:0] tx_state;
reg [24:0] captured_status;
reg        status_toggle_sys_d;

localparam TX_IDLE  = 3'd0;
localparam TX_BYTE0 = 3'd1;
localparam TX_BYTE1 = 3'd2;
localparam TX_BYTE2 = 3'd3;
localparam TX_BYTE3 = 3'd4;
localparam TX_WAIT  = 3'd5;

always @(posedge sys_clk or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
        tx_state            <= TX_IDLE;
        tx_data_r           <= 8'd0;
        tx_valid_r          <= 1'b0;
        captured_status     <= 25'd0;
        status_toggle_sys_d <= 1'b0;
    end else begin
        status_toggle_sys_d <= status_toggle_sys;
        case (tx_state)
            TX_IDLE: begin
                tx_valid_r <= 1'b0;
                if (status_toggle_sys ^ status_toggle_sys_d) begin
                    captured_status <= status_bus_sys;
                    tx_state        <= TX_BYTE0;
                end
            end
            TX_BYTE0: begin
                tx_data_r  <= 8'h55;
                tx_valid_r <= 1'b1;
                if (tx_ready_w) begin
                    tx_state <= TX_BYTE1;
                end
            end
            TX_BYTE1: begin
                tx_data_r  <= {captured_status[24:23], captured_status[17:16], captured_status[21:18]};
                tx_valid_r <= 1'b1;
                if (tx_ready_w) begin
                    tx_state <= TX_BYTE2;
                end
            end
            TX_BYTE2: begin
                tx_data_r  <= captured_status[15:8];
                tx_valid_r <= 1'b1;
                if (tx_ready_w) begin
                    tx_state <= TX_BYTE3;
                end
            end
            TX_BYTE3: begin
                tx_data_r  <= captured_status[7:0];
                tx_valid_r <= 1'b1;
                if (tx_ready_w) begin
                    tx_state <= TX_WAIT;
                end
            end
            TX_WAIT: begin
                tx_valid_r <= 1'b0;
                if (tx_ready_w) begin
                    tx_state <= TX_IDLE;
                end
            end
            default: tx_state <= TX_IDLE;
        endcase
    end
end

// ---------------------------------------------------------------------------
// Đường nạp trọng số từ ảnh flash vào DDR3
// ---------------------------------------------------------------------------
wire        weight_header_valid_unused;
wire        weight_entry_valid_unused;
wire [15:0] weight_entries_loaded_unused;
wire [15:0] weight_entry_count_unused;
wire [31:0] weight_image_len_unused;
wire [15:0] weight_entry_kind_unused;
wire [31:0] weight_entry_flash_offset_unused;
wire [28:0] weight_entry_ddr_addr_unused;
wire [31:0] weight_entry_size_unused;
wire [31:0] weight_entry_crc32_unused;
wire [31:0] weight_current_flash_offset_unused;
wire [28:0] weight_current_ddr_addr_unused;
wire [31:0] weight_current_size_unused;

weight_boot_loader u_weight_boot_loader (
    .sys_clk                   (sys_clk),
    .rst_n                     (sys_rst_n),
    .start                     (weight_boot_start),
    .busy                      (weight_boot_busy),
    .done                      (weight_boot_done),
    .error                     (weight_boot_error),
    .flash_data                (flash_weight_data),
    .flash_valid               (flash_weight_valid),
    .flash_ready               (flash_weight_ready),
    .header_valid              (weight_header_valid_unused),
    .entry_valid               (weight_entry_valid_unused),
    .entries_loaded            (weight_entries_loaded_unused),
    .entry_count_out           (weight_entry_count_unused),
    .image_len_out             (weight_image_len_unused),
    .entry_kind_out            (weight_entry_kind_unused),
    .entry_flash_offset_out    (weight_entry_flash_offset_unused),
    .entry_ddr_addr_out        (weight_entry_ddr_addr_unused),
    .entry_size_out            (weight_entry_size_unused),
    .entry_crc32_out           (weight_entry_crc32_unused),
    .current_entry_flash_offset(weight_current_flash_offset_unused),
    .current_entry_ddr_addr    (weight_current_ddr_addr_unused),
    .current_entry_size        (weight_current_size_unused),
    .ddr_cmd_ready             (ddr_cmd_ready),
    .ddr_cmd                   (ddr_cmd),
    .ddr_cmd_en                (ddr_cmd_en),
    .ddr_addr                  (ddr_addr),
    .ddr_wr_data_rdy           (ddr_wr_data_rdy),
    .ddr_wr_data               (ddr_wr_data),
    .ddr_wr_data_en            (ddr_wr_data_en),
    .ddr_wr_data_end           (ddr_wr_data_end),
    .ddr_wr_data_mask          (ddr_wr_data_mask)
);

// ---------------------------------------------------------------------------
// Đường hiển thị và module phụ trợ văn bản
// ---------------------------------------------------------------------------
wire [11:0] hcount;
wire [11:0] vcount;
wire        hs_unused;
wire        vs_unused;
wire        de;

vga_timing #(
    .H_ACTIVE(1280), .H_FP(110), .H_SYNC(40), .H_BP(220),
    .V_ACTIVE(720),  .V_FP(5),   .V_SYNC(5),  .V_BP(20),
    .HS_POL(1'b1),   .VS_POL(1'b1)
) u_vga (
    .clk     (pixel_clk),
    .rst     (~pixel_rst_n),
    .hs      (hs_unused),
    .vs      (vs_unused),
    .de      (de),
    .active_x(hcount),
    .active_y(vcount)
);

wire [23:0] wave_pixel;

waveform_display u_waveform_display (
    .sys_clk    (sys_clk),
    .rst_n      (sys_rst_n),
    .pixel_clk  (pixel_clk),
    .pixel_rst_n(pixel_rst_n),
    .eeg_sample (eeg_sample[15:8]),
    .eeg_valid  (eeg_valid),
    .ecg_sample (ecg_sample[15:8]),
    .ecg_valid  (ecg_valid),
    .emg_sample (emg_sample[15:8]),
    .emg_valid  (emg_valid),
    .hcount     (hcount),
    .vcount     (vcount),
    .de         (de),
    .pixel_out  (wave_pixel)
);

wire [7:0] osd_r;
wire [7:0] osd_g;
wire [7:0] osd_b;

osd_overlay u_osd_overlay (
    .pixel_clk        (pixel_clk),
    .rst_n            (pixel_rst_n),
    .hcount           (hcount),
    .vcount           (vcount),
    .de               (de),
    .class_out        (final_class),
    .triggered_sensors(triggered_sensors),
    .confidence       (confidence),
    .spo2_raw         (spo2_raw),
    .temp_raw         (temp_raw),
    .wave_pixel       (wave_pixel),
    .r_out            (osd_r),
    .g_out            (osd_g),
    .b_out            (osd_b)
);

wire [23:0] text_pixel;
wire        text_on;
wire [7:0]  status_char = 8'h41 + {6'd0, final_class};

text_renderer u_text_renderer_helper (
    .pixel_clk (pixel_clk),
    .rst_n     (pixel_rst_n),
    .hcount    (hcount),
    .vcount    (vcount),
    .char_ascii(status_char),
    .char_x    (12'd2),
    .char_y    (12'd2),
    .scale     (1'b0),
    .fg_color  (24'hffffff),
    .bg_color  (24'h000000),
    .bg_en     (1'b0),
    .pixel_out (text_pixel),
    .pixel_on  (text_on)
);

wire helper_debug = helper_windowed_valid ^ helper_mag_done ^
                    helper_mac_acc[0] ^ divided_clk_unused ^
                    (|helper_hamming_addr) ^ (|helper_mag[7:0]);

assign pixel_rgb = (text_on === 1'b1) ? text_pixel :
                   ({osd_r, osd_g, osd_b} ^ {24{helper_debug}});

endmodule
