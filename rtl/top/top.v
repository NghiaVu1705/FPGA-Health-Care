// top.v - Tang Mega 138K integrated biomedical AI + HDMI/DVI top.
// Vendor-facing shell stays in gowin_fpga/. Technology-neutral RTL lives in ../rtl/.
module top #(
    // Full 3-channel STFT+CNN replication currently exceeds GW5AST-138B DFF
    // capacity. Keep one AI lane for FPGA bring-up; ECG/EMG still feed the
    // waveform display and can be re-enabled after shared-lane/DDR work.
    parameter ENABLE_FULL_AI_LANES = 1'b0,
    // The current Tiny CNN stores whole feature maps in random-access buffers.
    // Gowin synthesis maps those multi-read buffers into logic instead of BSRAM,
    // so the FPGA bring-up build defaults to sensor/display/threshold mode.
    // Unit/subsystem verification still covers STFT/CNN directly, and this lane
    // can be re-enabled for simulation/full-mode experiments.
    parameter ENABLE_EEG_AI_LANE = 1'b0
)(
    input                  clk,
    input                  rst_n,
    input                  case_next_n,

    input                  uart_rx_emg,
    output                 uart_tx_debug,

    input                  spi_sck,
    input                  spi_mosi,
    input                  spi_cs_n,

    input                  i2c_scl,
    inout                  i2c_sda,

    output [15-1:0]        ddr_addr,
    output [3-1:0]         ddr_bank,
    output                 ddr_cs,
    output                 ddr_ras,
    output                 ddr_cas,
    output                 ddr_we,
    output                 ddr_ck,
    output                 ddr_ck_n,
    output                 ddr_cke,
    output                 ddr_odt,
    output                 ddr_reset_n,
    output [4-1:0]         ddr_dm,
    inout  [32-1:0]        ddr_dq,
    inout  [4-1:0]         ddr_dqs,
    inout  [4-1:0]         ddr_dqs_n,

    output                 tmds_clk_n_0,
    output                 tmds_clk_p_0,
    output [2:0]           tmds_d_n_0,
    output [2:0]           tmds_d_p_0
);

wire sys_clk;
wire pixel_clk;
wire serial_clk;
wire pll_sys_lock;
wire pll_hdmi_lock;
wire pll_lock = pll_sys_lock & pll_hdmi_lock;

gowin_pll_sys u_pll_sys (
    .clkout0(sys_clk),
    .lock   (pll_sys_lock),
    .clkin  (clk)
);

TMDS_PLL u_tmds_pll (
    .clkin   (clk),
    .init_clk(clk),
    .clkout0 (serial_clk),
    .clkout1 (pixel_clk),
    .lock    (pll_hdmi_lock)
);

wire sys_rst_n;
wire pixel_rst_n;

reset_sync u_rst_sys (
    .clk        (sys_clk),
    .rst_async_n(pll_lock & rst_n),
    .rst_sync_n (sys_rst_n)
);

reset_sync u_rst_pix (
    .clk        (pixel_clk),
    .rst_async_n(pll_lock & rst_n),
    .rst_sync_n (pixel_rst_n)
);

// ---------------------------------------------------------------------------
// Sensor ingress
// ---------------------------------------------------------------------------
wire [15:0] emg_sample;
wire        emg_valid;
wire [15:0] emg_sample_uart;
wire        emg_valid_uart;
// Debug UART transmitter FSM interface wires/regs
reg [7:0] tx_data_r;
reg       tx_valid_r;
wire      tx_ready_w;

uart_top #(
    .CLK_FRE  (100),
    .BAUD_RATE(115200)
) u_uart (
    .sys_clk   (sys_clk),
    .rst_n     (sys_rst_n),
    .uart_rx   (uart_rx_emg),
    .uart_tx   (uart_tx_debug),
    .emg_sample(emg_sample_uart),
    .emg_valid (emg_valid_uart),
    .dbg_data  (tx_data_r),
    .dbg_valid (tx_valid_r),
    .dbg_ready (tx_ready_w)
);

wire [15:0] spi_sample_raw;
wire        spi_valid_raw;
wire [1:0]  spi_channel_raw;

spi_slave u_spi (
    .sys_clk  (sys_clk),
    .rst_n    (sys_rst_n),
    .spi_sck  (spi_sck),
    .spi_mosi (spi_mosi),
    .spi_cs_n (spi_cs_n),
    .rx_data  (spi_sample_raw),
    .rx_valid (spi_valid_raw),
    .channel  (spi_channel_raw)
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

// ---------------------------------------------------------------------------
// Input FIFOs
// ---------------------------------------------------------------------------
wire [15:0] eeg_sample;
wire [15:0] ecg_sample_w;
wire        eeg_valid;
wire        ecg_valid;
wire        eeg_fifo_empty, eeg_fifo_full, eeg_fifo_rd;
wire        ecg_fifo_empty, ecg_fifo_full, ecg_fifo_rd;
wire        emg_fifo_empty, emg_fifo_full, emg_fifo_rd;

assign eeg_fifo_rd = !eeg_fifo_empty;
assign ecg_fifo_rd = !ecg_fifo_empty;
assign emg_fifo_rd = !emg_fifo_empty;

assign eeg_valid = eeg_fifo_rd;
assign ecg_valid = ecg_fifo_rd;
assign emg_valid = emg_fifo_rd;

gowin_fifo_async u_fifo_eeg (
    .Reset(~sys_rst_n),
    .WrClk(sys_clk),
    .RdClk(sys_clk),
    .WrEn(spi_valid_raw && (spi_channel_raw == 2'd0)),
    .RdEn(eeg_fifo_rd),
    .Data(spi_sample_raw),
    .Q(eeg_sample),
    .Empty(eeg_fifo_empty),
    .Full(eeg_fifo_full)
);

gowin_fifo_async u_fifo_ecg (
    .Reset(~sys_rst_n),
    .WrClk(sys_clk),
    .RdClk(sys_clk),
    .WrEn(spi_valid_raw && (spi_channel_raw == 2'd1)),
    .RdEn(ecg_fifo_rd),
    .Data(spi_sample_raw),
    .Q(ecg_sample_w),
    .Empty(ecg_fifo_empty),
    .Full(ecg_fifo_full)
);

gowin_fifo_async u_fifo_emg (
    .Reset(~sys_rst_n),
    .WrClk(sys_clk),
    .RdClk(sys_clk),
    .WrEn(emg_valid_uart),
    .RdEn(emg_fifo_rd),
    .Data(emg_sample_uart),
    .Q(emg_sample),
    .Empty(emg_fifo_empty),
    .Full(emg_fifo_full)
);

// ---------------------------------------------------------------------------
// STFT ROMs and pipelines
// ---------------------------------------------------------------------------
wire [5:0]  hamming_addr_eeg, hamming_addr_ecg, hamming_addr_emg;
wire [7:0]  hamming_data_eeg, hamming_data_ecg, hamming_data_emg;
wire [4:0]  twiddle_addr_eeg, twiddle_addr_ecg, twiddle_addr_emg;
wire [31:0] twiddle_data_eeg, twiddle_data_ecg, twiddle_data_emg;

wire [7:0] spec_eeg;
wire [7:0] spec_ecg;
wire [7:0] spec_emg;
wire       spec_eeg_valid;
wire       spec_ecg_valid;
wire       spec_emg_valid;

generate
    if (ENABLE_EEG_AI_LANE) begin : gen_eeg_stft_lane
        gowin_bsram_hamming u_hamming_eeg (
            .clk (sys_clk),
            .addr(hamming_addr_eeg),
            .dout(hamming_data_eeg)
        );

        gowin_bsram_twiddle u_twiddle_eeg (
            .clk (sys_clk),
            .addr(twiddle_addr_eeg),
            .dout(twiddle_data_eeg)
        );

        stft_top u_stft_eeg (
            .sys_clk         (sys_clk),
            .rst_n           (sys_rst_n),
            .sample_in       (eeg_sample),
            .sample_valid    (eeg_valid),
            .spec_out        (spec_eeg),
            .spec_valid      (spec_eeg_valid),
            .spec_ready      (1'b1),
            .hamming_rom_addr(hamming_addr_eeg),
            .hamming_rom_data(hamming_data_eeg),
            .twiddle_rom_addr(twiddle_addr_eeg),
            .twiddle_rom_data(twiddle_data_eeg)
        );
    end else begin : gen_no_eeg_stft_lane
        assign hamming_addr_eeg = 6'd0;
        assign hamming_data_eeg = 8'd0;
        assign twiddle_addr_eeg = 5'd0;
        assign twiddle_data_eeg = 32'd0;
        assign spec_eeg         = 8'd0;
        assign spec_eeg_valid   = 1'b0;
    end

    if (ENABLE_EEG_AI_LANE && ENABLE_FULL_AI_LANES) begin : gen_full_stft_lanes
        gowin_bsram_hamming u_hamming_ecg (
            .clk (sys_clk),
            .addr(hamming_addr_ecg),
            .dout(hamming_data_ecg)
        );

        gowin_bsram_hamming u_hamming_emg (
            .clk (sys_clk),
            .addr(hamming_addr_emg),
            .dout(hamming_data_emg)
        );

        gowin_bsram_twiddle u_twiddle_ecg (
            .clk (sys_clk),
            .addr(twiddle_addr_ecg),
            .dout(twiddle_data_ecg)
        );

        gowin_bsram_twiddle u_twiddle_emg (
            .clk (sys_clk),
            .addr(twiddle_addr_emg),
            .dout(twiddle_data_emg)
        );

        stft_top u_stft_ecg (
            .sys_clk         (sys_clk),
            .rst_n           (sys_rst_n),
            .sample_in       (ecg_sample_w),
            .sample_valid    (ecg_valid),
            .spec_out        (spec_ecg),
            .spec_valid      (spec_ecg_valid),
            .spec_ready      (1'b1),
            .hamming_rom_addr(hamming_addr_ecg),
            .hamming_rom_data(hamming_data_ecg),
            .twiddle_rom_addr(twiddle_addr_ecg),
            .twiddle_rom_data(twiddle_data_ecg)
        );

        stft_top u_stft_emg (
            .sys_clk         (sys_clk),
            .rst_n           (sys_rst_n),
            .sample_in       (emg_sample),
            .sample_valid    (emg_valid),
            .spec_out        (spec_emg),
            .spec_valid      (spec_emg_valid),
            .spec_ready      (1'b1),
            .hamming_rom_addr(hamming_addr_emg),
            .hamming_rom_data(hamming_data_emg),
            .twiddle_rom_addr(twiddle_addr_emg),
            .twiddle_rom_data(twiddle_data_emg)
        );
    end else begin : gen_lite_stft_lanes
        assign hamming_addr_ecg = 6'd0;
        assign hamming_addr_emg = 6'd0;
        assign hamming_data_ecg = 8'd0;
        assign hamming_data_emg = 8'd0;
        assign twiddle_addr_ecg = 5'd0;
        assign twiddle_addr_emg = 5'd0;
        assign twiddle_data_ecg = 32'd0;
        assign twiddle_data_emg = 32'd0;
        assign spec_ecg         = 8'd0;
        assign spec_emg         = 8'd0;
        assign spec_ecg_valid   = 1'b0;
        assign spec_emg_valid   = 1'b0;
    end
endgenerate

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

// ---------------------------------------------------------------------------
// CNN accelerators
// ---------------------------------------------------------------------------
wire [8:0] bsram_addr_eeg, bsram_addr_ecg, bsram_addr_emg;
wire [7:0] bsram_data_eeg, bsram_data_ecg, bsram_data_emg;

wire [1:0] cnn_eeg_class;
wire [1:0] cnn_ecg_class;
wire [1:0] cnn_emg_class;
wire       cnn_eeg_valid;
wire       cnn_ecg_valid;
wire       cnn_emg_valid;

generate
    if (ENABLE_EEG_AI_LANE) begin : gen_eeg_cnn_lane
        gowin_bsram_cnn_eeg u_cnn_rom_eeg (
            .clk (sys_clk),
            .addr(bsram_addr_eeg),
            .dout(bsram_data_eeg)
        );

        cnn_top u_cnn_eeg (
            .sys_clk    (sys_clk),
            .rst_n      (sys_rst_n),
            .spec_in    (spec_eeg),
            .spec_valid (spec_eeg_valid),
            .spec_start (spec_eeg_start),
            .class_out  (cnn_eeg_class),
            .class_valid(cnn_eeg_valid),
            .bsram_addr (bsram_addr_eeg),
            .bsram_data (bsram_data_eeg)
        );
    end else begin : gen_no_eeg_cnn_lane
        assign bsram_addr_eeg = 9'd0;
        assign bsram_data_eeg = 8'd0;
        assign cnn_eeg_class  = 2'd0;
        assign cnn_eeg_valid  = 1'b0;
    end

    if (ENABLE_EEG_AI_LANE && ENABLE_FULL_AI_LANES) begin : gen_full_cnn_lanes
        gowin_bsram_cnn_ecg u_cnn_rom_ecg (
            .clk (sys_clk),
            .addr(bsram_addr_ecg),
            .dout(bsram_data_ecg)
        );

        gowin_bsram_cnn_emg u_cnn_rom_emg (
            .clk (sys_clk),
            .addr(bsram_addr_emg),
            .dout(bsram_data_emg)
        );

        cnn_top u_cnn_ecg (
            .sys_clk    (sys_clk),
            .rst_n      (sys_rst_n),
            .spec_in    (spec_ecg),
            .spec_valid (spec_ecg_valid),
            .spec_start (spec_ecg_start),
            .class_out  (cnn_ecg_class),
            .class_valid(cnn_ecg_valid),
            .bsram_addr (bsram_addr_ecg),
            .bsram_data (bsram_data_ecg)
        );

        cnn_top u_cnn_emg (
            .sys_clk    (sys_clk),
            .rst_n      (sys_rst_n),
            .spec_in    (spec_emg),
            .spec_valid (spec_emg_valid),
            .spec_start (spec_emg_start),
            .class_out  (cnn_emg_class),
            .class_valid(cnn_emg_valid),
            .bsram_addr (bsram_addr_emg),
            .bsram_data (bsram_data_emg)
        );
    end else begin : gen_lite_cnn_lanes
        assign bsram_addr_ecg = 9'd0;
        assign bsram_addr_emg = 9'd0;
        assign bsram_data_ecg = 8'd0;
        assign bsram_data_emg = 8'd0;
        assign cnn_ecg_class  = 2'd0;
        assign cnn_emg_class  = 2'd0;
        assign cnn_ecg_valid  = 1'b0;
        assign cnn_emg_valid  = 1'b0;
    end
endgenerate

// ---------------------------------------------------------------------------
// Vitals threshold and decision fusion
// ---------------------------------------------------------------------------
(* syn_keep = 1 *) wire [1:0] spo2_class;
(* syn_keep = 1 *) wire [1:0] temp_class;

(* syn_noprune = 1 *) threshold_proc u_threshold (
    .spo2_raw  (spo2_raw),
    .temp_raw  (temp_raw),
    .spo2_class(spo2_class),
    .temp_class(temp_class)
);

wire case_next_pressed = ~case_next_n;
wire classes_pulse = cnn_eeg_valid | cnn_ecg_valid | cnn_emg_valid | vitals_updated | case_next_pressed;
wire [1:0] final_class;
wire [4:0] triggered_sensors;
wire [1:0] confidence;

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

// ---------------------------------------------------------------------------
// Display and DVI output
// ---------------------------------------------------------------------------
wire [11:0] hcount;
wire [11:0] vcount;
wire        hs;
wire        vs;
wire        de;

vga_timing #(
    .H_ACTIVE(1280), .H_FP(110), .H_SYNC(40), .H_BP(220),
    .V_ACTIVE(720),  .V_FP(5),   .V_SYNC(5),  .V_BP(20),
    .HS_POL(1'b1),   .VS_POL(1'b1)
) u_vga (
    .clk     (pixel_clk),
    .rst     (~pixel_rst_n),
    .hs      (hs),
    .vs      (vs),
    .de      (de),
    .active_x(hcount),
    .active_y(vcount)
);

wire [7:0] eeg_wave = eeg_sample[15:8];
wire [7:0] ecg_wave = ecg_sample_w[15:8];
wire [7:0] emg_wave = emg_sample[15:8];
wire [23:0] wave_pixel;

waveform_display u_wave (
    .sys_clk    (sys_clk),
    .rst_n      (sys_rst_n),
    .pixel_clk  (pixel_clk),
    .pixel_rst_n(pixel_rst_n),
    .eeg_sample (eeg_wave),
    .eeg_valid  (eeg_valid),
    .ecg_sample (ecg_wave),
    .ecg_valid  (ecg_valid),
    .emg_sample (emg_wave),
    .emg_valid  (emg_valid),
    .hcount     (hcount),
    .vcount     (vcount),
    .de         (de),
    .pixel_out  (wave_pixel)
);

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

reg        status_toggle_pix0, status_toggle_pix1, status_toggle_pix2;
reg [24:0] status_bus_pix0, status_bus_pix1;
reg [24:0] status_bus_pixel;

always @(posedge pixel_clk or negedge pixel_rst_n) begin
    if (!pixel_rst_n) begin
        status_toggle_pix0 <= 1'b0;
        status_toggle_pix1 <= 1'b0;
        status_toggle_pix2 <= 1'b0;
        status_bus_pix0    <= {2'd0, 5'd0, 2'd0, 8'd98, 8'd72};
        status_bus_pix1    <= {2'd0, 5'd0, 2'd0, 8'd98, 8'd72};
        status_bus_pixel   <= {2'd0, 5'd0, 2'd0, 8'd98, 8'd72};
    end else begin
        status_toggle_pix0 <= status_toggle_sys;
        status_toggle_pix1 <= status_toggle_pix0;
        status_toggle_pix2 <= status_toggle_pix1;
        status_bus_pix0    <= status_bus_sys;
        status_bus_pix1    <= status_bus_pix0;
        if (status_toggle_pix1 ^ status_toggle_pix2)
            status_bus_pixel <= status_bus_pix1;
    end
end

wire [1:0] final_class_pix       = status_bus_pixel[24:23];
wire [4:0] triggered_sensors_pix = status_bus_pixel[22:18];
wire [1:0] confidence_pix        = status_bus_pixel[17:16];
wire [7:0] spo2_raw_pix          = status_bus_pixel[15:8];
wire [7:0] temp_raw_pix          = status_bus_pixel[7:0];
wire [7:0] r_osd;
wire [7:0] g_osd;
wire [7:0] b_osd;

osd_overlay u_osd (
    .pixel_clk        (pixel_clk),
    .rst_n            (pixel_rst_n),
    .hcount           (hcount),
    .vcount           (vcount),
    .de               (de),
    .class_out        (final_class_pix),
    .triggered_sensors(triggered_sensors_pix),
    .confidence       (confidence_pix),
    .spo2_raw         (spo2_raw_pix),
    .temp_raw         (temp_raw_pix),
    .wave_pixel       (wave_pixel),
    .r_out            (r_osd),
    .g_out            (g_osd),
    .b_out            (b_osd)
);

reg hs_d1, vs_d1, de_d1;
reg hs_d2, vs_d2, de_d2;

always @(posedge pixel_clk or negedge pixel_rst_n) begin
    if (!pixel_rst_n) begin
        hs_d1 <= 1'b0;
        vs_d1 <= 1'b0;
        de_d1 <= 1'b0;
        hs_d2 <= 1'b0;
        vs_d2 <= 1'b0;
        de_d2 <= 1'b0;
    end else begin
        hs_d1 <= hs;
        vs_d1 <= vs;
        de_d1 <= de;
        hs_d2 <= hs_d1;
        vs_d2 <= vs_d1;
        de_d2 <= de_d1;
    end
end

DVI_TX_Top dvi_tx_i (
    .I_rst_n      (pixel_rst_n),
    .I_serial_clk (serial_clk),
    .I_rgb_clk    (pixel_clk),
    .I_rgb_vs     (vs_d2),
    .I_rgb_hs     (hs_d2),
    .I_rgb_de     (de_d2),
    .I_rgb_r      (r_osd),
    .I_rgb_g      (g_osd),
    .I_rgb_b      (b_osd),
    .O_tmds_clk_p (tmds_clk_p_0),
    .O_tmds_clk_n (tmds_clk_n_0),
    .O_tmds_data_p(tmds_d_p_0),
    .O_tmds_data_n(tmds_d_n_0)
);

// DDR3 and camera capture are not used by the current biomedical demo.
assign ddr_addr    = 15'd0;
assign ddr_bank    = 3'd0;
assign ddr_cs      = 1'b1;
assign ddr_ras     = 1'b1;
assign ddr_cas     = 1'b1;
assign ddr_we      = 1'b1;
assign ddr_ck      = 1'b0;
assign ddr_ck_n    = 1'b1;
assign ddr_cke     = 1'b0;
assign ddr_odt     = 1'b0;
assign ddr_reset_n = 1'b0;
assign ddr_dm      = 4'hf;
assign ddr_dq      = 32'hzzzz_zzzz;
assign ddr_dqs     = 4'hz;
assign ddr_dqs_n   = 4'hz;

endmodule
