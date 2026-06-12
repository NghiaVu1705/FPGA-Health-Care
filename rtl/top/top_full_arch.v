// top_full_arch.v - synthesis-oriented full biomedical architecture top.
//
// This top keeps the Tang Mega 138K board-level ports so GowinIDE constraints
// still find their objects, but it is intended for architecture synthesis and
// resource analysis. The real board bitstream should continue to use top.v
// until the Gowin DDR3MI controller and flash/QSPI reader are wired in.
module top_full_arch (
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

// A tiny synthetic flash stream keeps the weight-loader and DDR3 native write
// boundary alive in synthesis. Replace this with QSPI/flash reader output for
// a real board implementation.
reg [15:0] boot_delay;
reg        boot_started;
reg [7:0]  flash_counter;

wire        flash_weight_ready;
wire        weight_boot_busy;
wire        weight_boot_done;
wire        weight_boot_error;
wire        weight_boot_start = sys_rst_n && !boot_started && (boot_delay == 16'h00ff);
wire [7:0]  flash_weight_data = flash_counter;
wire        flash_weight_valid = weight_boot_busy;

always @(posedge sys_clk or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
        boot_delay    <= 16'd0;
        boot_started  <= 1'b0;
        flash_counter <= 8'd0;
    end else begin
        if (!boot_started)
            boot_delay <= boot_delay + 1'b1;

        if (weight_boot_start)
            boot_started <= 1'b1;

        if (flash_weight_valid && flash_weight_ready)
            flash_counter <= flash_counter + 1'b1;
    end
end

wire [2:0]   native_ddr_cmd;
wire         native_ddr_cmd_en;
wire [28:0]  native_ddr_addr;
wire [255:0] native_ddr_wr_data;
wire         native_ddr_wr_data_en;
wire         native_ddr_wr_data_end;
wire [31:0]  native_ddr_wr_data_mask;

wire [23:0] full_pixel_rgb;
wire [1:0]  final_class;
wire [4:0]  triggered_sensors;
wire [1:0]  confidence;

wire [5:0] hamming_addr_eeg;
wire [5:0] hamming_addr_ecg;
wire [5:0] hamming_addr_emg;
wire [7:0] hamming_data_eeg;
wire [7:0] hamming_data_ecg;
wire [7:0] hamming_data_emg;

wire [4:0]  twiddle_addr_eeg;
wire [4:0]  twiddle_addr_ecg;
wire [4:0]  twiddle_addr_emg;
wire [31:0] twiddle_data_eeg;
wire [31:0] twiddle_data_ecg;
wire [31:0] twiddle_data_emg;

wire [8:0] cnn_addr_eeg;
wire [8:0] cnn_addr_ecg;
wire [8:0] cnn_addr_emg;
wire [7:0] cnn_data_eeg;
wire [7:0] cnn_data_ecg;
wire [7:0] cnn_data_emg;

gowin_bsram_hamming u_hamming_rom_eeg (
    .clk (sys_clk),
    .addr(hamming_addr_eeg),
    .dout(hamming_data_eeg)
);

gowin_bsram_hamming u_hamming_rom_ecg (
    .clk (sys_clk),
    .addr(hamming_addr_ecg),
    .dout(hamming_data_ecg)
);

gowin_bsram_hamming u_hamming_rom_emg (
    .clk (sys_clk),
    .addr(hamming_addr_emg),
    .dout(hamming_data_emg)
);

gowin_bsram_twiddle u_twiddle_rom_eeg (
    .clk (sys_clk),
    .addr(twiddle_addr_eeg),
    .dout(twiddle_data_eeg)
);

gowin_bsram_twiddle u_twiddle_rom_ecg (
    .clk (sys_clk),
    .addr(twiddle_addr_ecg),
    .dout(twiddle_data_ecg)
);

gowin_bsram_twiddle u_twiddle_rom_emg (
    .clk (sys_clk),
    .addr(twiddle_addr_emg),
    .dout(twiddle_data_emg)
);

gowin_bsram_cnn_eeg u_cnn_weight_rom_eeg (
    .clk (sys_clk),
    .addr(cnn_addr_eeg),
    .dout(cnn_data_eeg)
);

gowin_bsram_cnn_ecg u_cnn_weight_rom_ecg (
    .clk (sys_clk),
    .addr(cnn_addr_ecg),
    .dout(cnn_data_ecg)
);

gowin_bsram_cnn_emg u_cnn_weight_rom_emg (
    .clk (sys_clk),
    .addr(cnn_addr_emg),
    .dout(cnn_data_emg)
);

biomed_full_system u_biomed_full_system (
    .sys_clk             (sys_clk),
    .pixel_clk           (pixel_clk),
    .rst_n               (sys_rst_n & pixel_rst_n),
    .uart_rx_emg         (uart_rx_emg),
    .uart_tx_debug       (uart_tx_debug),
    .spi_sck             (spi_sck),
    .spi_mosi            (spi_mosi),
    .spi_cs_n            (spi_cs_n),
    .i2c_scl             (i2c_scl),
    .i2c_sda             (i2c_sda),
    .case_next_n         (case_next_n),
    .hamming_addr_eeg_out(hamming_addr_eeg),
    .hamming_addr_ecg_out(hamming_addr_ecg),
    .hamming_addr_emg_out(hamming_addr_emg),
    .hamming_data_eeg_in (hamming_data_eeg),
    .hamming_data_ecg_in (hamming_data_ecg),
    .hamming_data_emg_in (hamming_data_emg),
    .twiddle_addr_eeg_out(twiddle_addr_eeg),
    .twiddle_addr_ecg_out(twiddle_addr_ecg),
    .twiddle_addr_emg_out(twiddle_addr_emg),
    .twiddle_data_eeg_in (twiddle_data_eeg),
    .twiddle_data_ecg_in (twiddle_data_ecg),
    .twiddle_data_emg_in (twiddle_data_emg),
    .cnn_addr_eeg_out    (cnn_addr_eeg),
    .cnn_addr_ecg_out    (cnn_addr_ecg),
    .cnn_addr_emg_out    (cnn_addr_emg),
    .cnn_data_eeg_in     (cnn_data_eeg),
    .cnn_data_ecg_in     (cnn_data_ecg),
    .cnn_data_emg_in     (cnn_data_emg),
    .weight_boot_start   (weight_boot_start),
    .flash_weight_data   (flash_weight_data),
    .flash_weight_valid  (flash_weight_valid),
    .flash_weight_ready  (flash_weight_ready),
    .weight_boot_busy    (weight_boot_busy),
    .weight_boot_done    (weight_boot_done),
    .weight_boot_error   (weight_boot_error),
    .ddr_cmd_ready       (1'b1),
    .ddr_cmd             (native_ddr_cmd),
    .ddr_cmd_en          (native_ddr_cmd_en),
    .ddr_addr            (native_ddr_addr),
    .ddr_wr_data_rdy     (1'b1),
    .ddr_wr_data         (native_ddr_wr_data),
    .ddr_wr_data_en      (native_ddr_wr_data_en),
    .ddr_wr_data_end     (native_ddr_wr_data_end),
    .ddr_wr_data_mask    (native_ddr_wr_data_mask),
    .pixel_rgb           (full_pixel_rgb),
    .final_class         (final_class),
    .triggered_sensors   (triggered_sensors),
    .confidence          (confidence)
);

wire weight_debug = weight_boot_busy ^ weight_boot_done ^ weight_boot_error ^
                    flash_weight_ready ^ native_ddr_cmd_en ^
                    native_ddr_wr_data_en ^ native_ddr_wr_data_end ^
                    (^native_ddr_cmd) ^ (^native_ddr_addr) ^
                    (^native_ddr_wr_data) ^ (^native_ddr_wr_data_mask);

wire [11:0] hcount;
wire [11:0] vcount;
wire        hs;
wire        vs;
wire        de;

vga_timing #(
    .H_ACTIVE(1280), .H_FP(110), .H_SYNC(40), .H_BP(220),
    .V_ACTIVE(720),  .V_FP(5),   .V_SYNC(5),  .V_BP(20),
    .HS_POL(1'b1),   .VS_POL(1'b1)
) u_dvi_timing (
    .clk     (pixel_clk),
    .rst     (~pixel_rst_n),
    .hs      (hs),
    .vs      (vs),
    .de      (de),
    .active_x(hcount),
    .active_y(vcount)
);

wire [23:0] dvi_rgb = full_pixel_rgb ^ {24{weight_debug}};

DVI_TX_Top dvi_tx_i (
    .I_rst_n      (pixel_rst_n),
    .I_serial_clk (serial_clk),
    .I_rgb_clk    (pixel_clk),
    .I_rgb_vs     (vs),
    .I_rgb_hs     (hs),
    .I_rgb_de     (de),
    .I_rgb_r      (dvi_rgb[23:16]),
    .I_rgb_g      (dvi_rgb[15:8]),
    .I_rgb_b      (dvi_rgb[7:0]),
    .O_tmds_clk_p (tmds_clk_p_0),
    .O_tmds_clk_n (tmds_clk_n_0),
    .O_tmds_data_p(tmds_d_p_0),
    .O_tmds_data_n(tmds_d_n_0)
);

// Safe idle values for the physical DDR3 bus. The native DDR debug path above
// is preserved through the DVI pixel XOR, not by directly driving DDR3 pins.
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
