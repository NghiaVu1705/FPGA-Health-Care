// waveform_display.v — Scrolling waveform, 3 channels
// Display area: 1280×600 pixels, split into 3 horizontal bands:
//   EEG:  rows   0..199  (200 px)
//   ECG:  rows 200..399  (200 px)
//   EMG:  rows 400..599  (200 px)
//
// Each channel uses a 2048-sample circular buffer to scroll the waveform.
// Samples normalized to WAVE_H-px height.
module waveform_display (
    input  sys_clk,
    input  rst_n,
    input  pixel_clk,
    input  pixel_rst_n,

    // Sample inputs (one per channel, one per sample valid)
    input  [7:0] eeg_sample,   // UINT8 [0..255], normalized ADC amplitude
    input        eeg_valid,
    input  [7:0] ecg_sample,
    input        ecg_valid,
    input  [7:0] emg_sample,
    input        emg_valid,

    // VGA position
    input  [11:0] hcount,
    input  [11:0] vcount,
    input         de,

    // Output pixel
    output reg [23:0] pixel_out
);

// Medical-monitor layout: 3 lanes x 200 px in rows 0..599 (HUD now owns 600..719).
localparam [11:0] WAVE_H  = 12'd200;   // height per channel
localparam [11:0] W_EEG_T = 12'd0;
localparam [11:0] W_ECG_T = 12'd200;
localparam [11:0] W_EMG_T = 12'd400;
localparam [11:0] WAVE_BOT = 12'd600;  // first row below the waveform area

localparam [23:0]
    COLOR_EEG  = 24'h00FF88,
    COLOR_ECG  = 24'hFF4444,
    COLOR_EMG  = 24'h4488FF,
    COLOR_BG   = 24'h111111,
    COLOR_GRID = 24'h222222;

// ── Waveform buffers (2048-deep circular buffers, display reads 1280 columns) ─
(* syn_ramstyle = "block_ram" *) reg [7:0]  eeg_buf [0:2047];
(* syn_ramstyle = "block_ram" *) reg [7:0]  ecg_buf [0:2047];
(* syn_ramstyle = "block_ram" *) reg [7:0]  emg_buf [0:2047];
reg [10:0] eeg_wr_ptr, ecg_wr_ptr, emg_wr_ptr;
reg [10:0] eeg_wr_ptr_gray, ecg_wr_ptr_gray, emg_wr_ptr_gray;

function [10:0] bin2gray11;
    input [10:0] bin;
    begin
        bin2gray11 = bin ^ (bin >> 1);
    end
endfunction

function [10:0] gray2bin11;
    input [10:0] gray;
    integer i;
    begin
        gray2bin11[10] = gray[10];
        for (i = 9; i >= 0; i = i - 1)
            gray2bin11[i] = gray2bin11[i+1] ^ gray[i];
    end
endfunction

// Write: advance write pointer and store sample (sys_clk domain)
wire [10:0] eeg_wr_ptr_next = eeg_wr_ptr + 1'b1;
wire [10:0] ecg_wr_ptr_next = ecg_wr_ptr + 1'b1;
wire [10:0] emg_wr_ptr_next = emg_wr_ptr + 1'b1;

always @(posedge sys_clk) begin
    if (!rst_n) begin
        eeg_wr_ptr      <= 11'd0;
        ecg_wr_ptr      <= 11'd0;
        emg_wr_ptr      <= 11'd0;
        eeg_wr_ptr_gray <= 11'd0;
        ecg_wr_ptr_gray <= 11'd0;
        emg_wr_ptr_gray <= 11'd0;
    end else begin
        if (eeg_valid) begin
            eeg_buf[eeg_wr_ptr] <= eeg_sample;
            eeg_wr_ptr <= eeg_wr_ptr_next;
            eeg_wr_ptr_gray <= bin2gray11(eeg_wr_ptr_next);
        end
        if (ecg_valid) begin
            ecg_buf[ecg_wr_ptr] <= ecg_sample;
            ecg_wr_ptr <= ecg_wr_ptr_next;
            ecg_wr_ptr_gray <= bin2gray11(ecg_wr_ptr_next);
        end
        if (emg_valid) begin
            emg_buf[emg_wr_ptr] <= emg_sample;
            emg_wr_ptr <= emg_wr_ptr_next;
            emg_wr_ptr_gray <= bin2gray11(emg_wr_ptr_next);
        end
    end
end

// ── Pixel generation (pixel_clk domain) ──────────────────────────────────────
// Map column → circular buffer index
reg [10:0] eeg_wr_ptr_gray_pix0, eeg_wr_ptr_gray_pix1;
reg [10:0] ecg_wr_ptr_gray_pix0, ecg_wr_ptr_gray_pix1;
reg [10:0] emg_wr_ptr_gray_pix0, emg_wr_ptr_gray_pix1;
wire [10:0] eeg_wr_ptr_pixel = gray2bin11(eeg_wr_ptr_gray_pix1);
wire [10:0] ecg_wr_ptr_pixel = gray2bin11(ecg_wr_ptr_gray_pix1);
wire [10:0] emg_wr_ptr_pixel = gray2bin11(emg_wr_ptr_gray_pix1);
wire [11:0] eeg_rd_sum = {1'b0, eeg_wr_ptr_pixel} + {1'b0, hcount[10:0]} + 12'd1;
wire [11:0] ecg_rd_sum = {1'b0, ecg_wr_ptr_pixel} + {1'b0, hcount[10:0]} + 12'd1;
wire [11:0] emg_rd_sum = {1'b0, emg_wr_ptr_pixel} + {1'b0, hcount[10:0]} + 12'd1;
wire [10:0] eeg_rd_idx = eeg_rd_sum[10:0];
wire [10:0] ecg_rd_idx = ecg_rd_sum[10:0];
wire [10:0] emg_rd_idx = emg_rd_sum[10:0];

// ── Pixel pipeline (pixel_clk domain) ────────────────────────────────────────
// Timing fix: the old design ran BRAM-read → ×220 scale → vertical-offset →
// beam compare → colour mux in a single cycle (worst path, slack -4.139 ns).
// It is now a 5-stage pipeline; the VGA control signals (hcount/vcount/de) are
// delayed in lock-step so every stage compares time-aligned data. The visible
// result is unchanged apart from a fixed +3-pixel pipeline latency.
//
//   S0  BRAM sample read     -> eeg_val / ecg_val / emg_val
//   S1  scale (× WAVE_H)      -> eeg_sy1 / ...           (1 multiply)
//   S2  vertical band offset  -> eeg_y2  / ...           (1 subtract)
//   S3  beam + grid + bg cmp  -> draw_*3 / grid3 / bg3   (compares)
//   S4  priority colour mux   -> pixel_out

// S0 outputs
reg [11:0] hcount_r,  vcount_r;
reg        de_r;
reg [7:0]  eeg_val, ecg_val, emg_val;

// S1 outputs (scaled amplitude, 0..219)
reg [11:0] hcount_r1, vcount_r1;
reg        de_r1;
reg [11:0] eeg_sy1, ecg_sy1, emg_sy1;

// S2 outputs (vertical pixel position within channel band)
reg [11:0] hcount_r2, vcount_r2;
reg        de_r2;
reg [11:0] eeg_y2, ecg_y2, emg_y2;

// S3 outputs (registered draw / grid / background decisions)
reg        draw_eeg3, draw_ecg3, draw_emg3;
reg        grid3, bg3;

// ---- S0: gray-pointer CDC sync + BRAM sample read ----
always @(posedge pixel_clk) begin
    if (!pixel_rst_n) begin
        eeg_wr_ptr_gray_pix0 <= 11'd0;
        eeg_wr_ptr_gray_pix1 <= 11'd0;
        ecg_wr_ptr_gray_pix0 <= 11'd0;
        ecg_wr_ptr_gray_pix1 <= 11'd0;
        emg_wr_ptr_gray_pix0 <= 11'd0;
        emg_wr_ptr_gray_pix1 <= 11'd0;
        hcount_r             <= 12'd0;
        vcount_r             <= 12'd0;
        de_r                 <= 1'b0;
        eeg_val              <= 8'd0;
        ecg_val              <= 8'd0;
        emg_val              <= 8'd0;
    end else begin
        eeg_wr_ptr_gray_pix0 <= eeg_wr_ptr_gray;
        eeg_wr_ptr_gray_pix1 <= eeg_wr_ptr_gray_pix0;
        ecg_wr_ptr_gray_pix0 <= ecg_wr_ptr_gray;
        ecg_wr_ptr_gray_pix1 <= ecg_wr_ptr_gray_pix0;
        emg_wr_ptr_gray_pix0 <= emg_wr_ptr_gray;
        emg_wr_ptr_gray_pix1 <= emg_wr_ptr_gray_pix0;
        hcount_r             <= hcount;
        vcount_r             <= vcount;
        de_r                 <= de;
        eeg_val              <= eeg_buf[eeg_rd_idx];
        ecg_val              <= ecg_buf[ecg_rd_idx];
        emg_val              <= emg_buf[emg_rd_idx];
    end
end

// ---- S1: scale [0..255] → [0..219] for 220-px channel height ----
wire [23:0] eeg_scaled_full = {16'd0, eeg_val} * WAVE_H;
wire [23:0] ecg_scaled_full = {16'd0, ecg_val} * WAVE_H;
wire [23:0] emg_scaled_full = {16'd0, emg_val} * WAVE_H;
always @(posedge pixel_clk) begin
    if (!pixel_rst_n) begin
        hcount_r1 <= 12'd0; vcount_r1 <= 12'd0; de_r1 <= 1'b0;
        eeg_sy1   <= 12'd0; ecg_sy1   <= 12'd0; emg_sy1 <= 12'd0;
    end else begin
        hcount_r1 <= hcount_r; vcount_r1 <= vcount_r; de_r1 <= de_r;
        eeg_sy1   <= eeg_scaled_full[19:8];
        ecg_sy1   <= ecg_scaled_full[19:8];
        emg_sy1   <= emg_scaled_full[19:8];
    end
end

// ---- S2: vertical position = band_top + WAVE_H - 1 - scaled_amplitude ----
wire [12:0] eeg_y_full = {1'b0, W_EEG_T} + {1'b0, WAVE_H} - 13'd1 - {1'b0, eeg_sy1};
wire [12:0] ecg_y_full = {1'b0, W_ECG_T} + {1'b0, WAVE_H} - 13'd1 - {1'b0, ecg_sy1};
wire [12:0] emg_y_full = {1'b0, W_EMG_T} + {1'b0, WAVE_H} - 13'd1 - {1'b0, emg_sy1};
always @(posedge pixel_clk) begin
    if (!pixel_rst_n) begin
        hcount_r2 <= 12'd0; vcount_r2 <= 12'd0; de_r2 <= 1'b0;
        eeg_y2    <= 12'd0; ecg_y2    <= 12'd0; emg_y2 <= 12'd0;
    end else begin
        hcount_r2 <= hcount_r1; vcount_r2 <= vcount_r1; de_r2 <= de_r1;
        eeg_y2    <= eeg_y_full[11:0];
        ecg_y2    <= ecg_y_full[11:0];
        emg_y2    <= emg_y_full[11:0];
    end
end

// ---- S3: beam (±2 px), grid and background compares (all registered) ----
wire draw_eeg_c = (vcount_r2 >= W_EEG_T) && (vcount_r2 < W_ECG_T) &&
                  (vcount_r2 >= eeg_y2 - 12'd2) && (vcount_r2 <= eeg_y2 + 12'd2);
wire draw_ecg_c = (vcount_r2 >= W_ECG_T) && (vcount_r2 < W_EMG_T) &&
                  (vcount_r2 >= ecg_y2 - 12'd2) && (vcount_r2 <= ecg_y2 + 12'd2);
wire draw_emg_c = (vcount_r2 >= W_EMG_T) && (vcount_r2 < WAVE_BOT) &&
                  (vcount_r2 >= emg_y2 - 12'd2) && (vcount_r2 <= emg_y2 + 12'd2);
wire grid_h_c = (vcount_r2 == W_EEG_T) || (vcount_r2 == W_ECG_T) ||
                (vcount_r2 == W_EMG_T) || (vcount_r2 == WAVE_BOT - 12'd1) ||
                (vcount_r2 == W_EEG_T + (WAVE_H >> 1)) ||
                (vcount_r2 == W_ECG_T + (WAVE_H >> 1)) ||
                (vcount_r2 == W_EMG_T + (WAVE_H >> 1));
wire grid_v_c = (hcount_r2[4:0] == 0);   // vertical line every 32 pixels
always @(posedge pixel_clk) begin
    if (!pixel_rst_n) begin
        draw_eeg3 <= 1'b0; draw_ecg3 <= 1'b0; draw_emg3 <= 1'b0;
        grid3     <= 1'b0; bg3       <= 1'b0;
    end else begin
        draw_eeg3 <= draw_eeg_c;
        draw_ecg3 <= draw_ecg_c;
        draw_emg3 <= draw_emg_c;
        grid3     <= grid_h_c || grid_v_c;
        bg3       <= (!de_r2) || (vcount_r2 >= WAVE_BOT);
    end
end

// ---- S4: priority colour mux ----
always @(posedge pixel_clk) begin
    if (!pixel_rst_n) begin
        pixel_out <= 24'd0;
    end else begin
        if (bg3)            pixel_out <= COLOR_BG;
        else if (draw_eeg3) pixel_out <= COLOR_EEG;
        else if (draw_ecg3) pixel_out <= COLOR_ECG;
        else if (draw_emg3) pixel_out <= COLOR_EMG;
        else if (grid3)     pixel_out <= COLOR_GRID;
        else                pixel_out <= COLOR_BG;
    end
end

endmodule
