`timescale 1ns/1ps

// Verification wrapper for the true shared-AI path:
// flash image -> weight_boot_loader -> behavioral DDR3 memory ->
// ddr3_weight_prefetcher -> weight cache -> STFT -> CNN -> decision -> OSD.
module shared_ai_full_pipeline_tb #(
    parameter integer DDR_BYTES = 131072
)(
    input                  sys_clk,
    input                  rst_n,

    input                  boot_start,
    input      [7:0]       flash_data,
    input                  flash_valid,
    output                 flash_ready,
    output                 weight_load_done,
    output                 weight_load_error,

    input      signed [15:0] eeg_sample,
    input                    eeg_valid,
    output                   eeg_ready,
    input      signed [15:0] ecg_sample,
    input                    ecg_valid,
    output                   ecg_ready,
    input      signed [15:0] emg_sample,
    input                    emg_valid,
    output                   emg_ready,

    input      [7:0]       spo2_raw,
    input      [7:0]       temp_raw,
    input                  vitals_updated,

    output     [1:0]       active_channel,
    output                 ai_busy,
    output                 weights_ready,
    output                 weight_prefetch_error,
    output                 cnn_timeout_error,
    output     [1:0]       final_class,
    output     [4:0]       triggered_sensors,
    output     [1:0]       confidence,
    output                 decision_update,

    output     [11:0]      hcount,
    output     [11:0]      vcount,
    output                 de,
    output     [7:0]       osd_r,
    output     [7:0]       osd_g,
    output     [7:0]       osd_b,

    output reg             ddr_write_seen,
    output reg             ddr_read_seen,
    output reg [31:0]      boot_write_count,
    output reg [31:0]      ai_read_count
);

wire boot_busy;
wire boot_done;
wire boot_error;
wire boot_crc_error;

wire [2:0]   boot_ddr_cmd;
wire         boot_ddr_cmd_en;
wire [28:0]  boot_ddr_addr;
wire [255:0] boot_ddr_wr_data;
wire         boot_ddr_wr_data_en;
wire         boot_ddr_wr_data_end;
wire [31:0]  boot_ddr_wr_data_mask;

wire [2:0]  ai_ddr_cmd;
wire        ai_ddr_cmd_en;
wire [28:0] ai_ddr_addr;
reg  [255:0] ai_ddr_rd_data;
reg          ai_ddr_rd_data_valid;
reg          ai_ddr_rd_data_end;

reg weight_load_done_r;
reg weight_load_error_r;
assign weight_load_done  = weight_load_done_r;
assign weight_load_error = weight_load_error_r;

wire run_enable = weight_load_done_r && !weight_load_error_r;

weight_boot_loader u_weight_boot_loader (
    .sys_clk                   (sys_clk),
    .rst_n                     (rst_n),
    .start                     (boot_start),
    .busy                      (boot_busy),
    .done                      (boot_done),
    .error                     (boot_error),
    .crc_error                 (boot_crc_error),
    .flash_data                (flash_data),
    .flash_valid               (flash_valid),
    .flash_ready               (flash_ready),
    .header_valid              (),
    .entry_valid               (),
    .entries_loaded            (),
    .entry_count_out           (),
    .image_len_out             (),
    .entry_kind_out            (),
    .entry_flash_offset_out    (),
    .entry_ddr_addr_out        (),
    .entry_size_out            (),
    .entry_crc32_out           (),
    .current_entry_flash_offset(),
    .current_entry_ddr_addr    (),
    .current_entry_size        (),
    .ddr_cmd_ready             (!run_enable),
    .ddr_cmd                   (boot_ddr_cmd),
    .ddr_cmd_en                (boot_ddr_cmd_en),
    .ddr_addr                  (boot_ddr_addr),
    .ddr_wr_data_rdy           (!run_enable),
    .ddr_wr_data               (boot_ddr_wr_data),
    .ddr_wr_data_en            (boot_ddr_wr_data_en),
    .ddr_wr_data_end           (boot_ddr_wr_data_end),
    .ddr_wr_data_mask          (boot_ddr_wr_data_mask)
);

reg [7:0] ddr_mem [0:DDR_BYTES-1];
integer mem_i;
integer byte_i;

initial begin
    for (mem_i = 0; mem_i < DDR_BYTES; mem_i = mem_i + 1)
        ddr_mem[mem_i] = 8'd0;
end

always @(posedge sys_clk or negedge rst_n) begin
    if (!rst_n) begin
        weight_load_done_r   <= 1'b0;
        weight_load_error_r  <= 1'b0;
        ddr_write_seen       <= 1'b0;
        ddr_read_seen        <= 1'b0;
        boot_write_count     <= 32'd0;
        ai_read_count        <= 32'd0;
        ai_ddr_rd_data       <= 256'd0;
        ai_ddr_rd_data_valid <= 1'b0;
        ai_ddr_rd_data_end   <= 1'b0;
    end else begin
        ai_ddr_rd_data_valid <= 1'b0;
        ai_ddr_rd_data_end   <= 1'b0;

        if (boot_start) begin
            weight_load_done_r  <= 1'b0;
            weight_load_error_r <= 1'b0;
        end

        if (boot_done)
            weight_load_done_r <= 1'b1;
        if (boot_error || boot_crc_error)
            weight_load_error_r <= 1'b1;

        if (boot_ddr_cmd_en && boot_ddr_wr_data_en) begin
            ddr_write_seen   <= 1'b1;
            boot_write_count <= boot_write_count + 1'b1;
            for (byte_i = 0; byte_i < 32; byte_i = byte_i + 1) begin
                if (!boot_ddr_wr_data_mask[byte_i] &&
                    ((boot_ddr_addr + byte_i) < DDR_BYTES)) begin
                    ddr_mem[boot_ddr_addr + byte_i] <= boot_ddr_wr_data[(byte_i * 8) +: 8];
                end
            end
        end

        if (run_enable && ai_ddr_cmd_en && (ai_ddr_cmd == 3'b001)) begin
            ddr_read_seen  <= 1'b1;
            ai_read_count  <= ai_read_count + 1'b1;
            for (byte_i = 0; byte_i < 32; byte_i = byte_i + 1) begin
                if ((ai_ddr_addr + byte_i) < DDR_BYTES)
                    ai_ddr_rd_data[(byte_i * 8) +: 8] <= ddr_mem[ai_ddr_addr + byte_i];
                else
                    ai_ddr_rd_data[(byte_i * 8) +: 8] <= 8'd0;
            end
            ai_ddr_rd_data_valid <= 1'b1;
            ai_ddr_rd_data_end   <= 1'b1;
        end
    end
end

wire [5:0]  hamming_addr;
wire [7:0]  hamming_data;
wire [4:0]  twiddle_addr;
wire [31:0] twiddle_data;

gowin_bsram_hamming u_hamming_rom (
    .clk (sys_clk),
    .addr(hamming_addr),
    .dout(hamming_data)
);

gowin_bsram_twiddle u_twiddle_rom (
    .clk (sys_clk),
    .addr(twiddle_addr),
    .dout(twiddle_data)
);

biomed_shared_ai_system u_shared_ai (
    .sys_clk              (sys_clk),
    .rst_n                (rst_n && run_enable),
    .eeg_sample           (eeg_sample),
    .eeg_valid            (eeg_valid),
    .eeg_ready            (eeg_ready),
    .ecg_sample           (ecg_sample),
    .ecg_valid            (ecg_valid),
    .ecg_ready            (ecg_ready),
    .emg_sample           (emg_sample),
    .emg_valid            (emg_valid),
    .emg_ready            (emg_ready),
    .spo2_raw             (spo2_raw),
    .temp_raw             (temp_raw),
    .vitals_updated       (vitals_updated),
    .hamming_rom_addr     (hamming_addr),
    .hamming_rom_data     (hamming_data),
    .twiddle_rom_addr     (twiddle_addr),
    .twiddle_rom_data     (twiddle_data),
    .ddr_cmd_ready        (run_enable),
    .ddr_cmd              (ai_ddr_cmd),
    .ddr_cmd_en           (ai_ddr_cmd_en),
    .ddr_addr             (ai_ddr_addr),
    .ddr_rd_data          (ai_ddr_rd_data),
    .ddr_rd_data_valid    (ai_ddr_rd_data_valid),
    .ddr_rd_data_end      (ai_ddr_rd_data_end),
    .active_channel       (active_channel),
    .ai_busy              (ai_busy),
    .weights_ready        (weights_ready),
    .weight_prefetch_error(weight_prefetch_error),
    .cnn_timeout_error    (cnn_timeout_error),
    .final_class          (final_class),
    .triggered_sensors    (triggered_sensors),
    .confidence           (confidence),
    .decision_update      (decision_update)
);

wire hs_unused;
wire vs_unused;
vga_timing #(
    .H_ACTIVE(1280), .H_FP(110), .H_SYNC(40), .H_BP(220),
    .V_ACTIVE(720),  .V_FP(5),   .V_SYNC(5),  .V_BP(20),
    .HS_POL(1'b1),   .VS_POL(1'b1)
) u_vga (
    .clk     (sys_clk),
    .rst     (~rst_n),
    .hs      (hs_unused),
    .vs      (vs_unused),
    .de      (de),
    .active_x(hcount),
    .active_y(vcount)
);

wire [23:0] wave_pixel;
waveform_display u_wave (
    .sys_clk    (sys_clk),
    .rst_n      (rst_n),
    .pixel_clk  (sys_clk),
    .pixel_rst_n(rst_n),
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

osd_overlay u_osd (
    .pixel_clk        (sys_clk),
    .rst_n            (rst_n),
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

endmodule
