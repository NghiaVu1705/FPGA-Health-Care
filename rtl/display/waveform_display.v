// waveform_display.v — Hiển thị dạng sóng cuộn, 3 kênh
// Vùng hiển thị: 1280×600 điểm ảnh, chia thành 3 dải ngang:
//   EEG:  hàng   0..199  (200 px)
//   ECG:  hàng 200..399  (200 px)
//   EMG:  hàng 400..599  (200 px)
//
// Mỗi kênh dùng một bộ đệm vòng 2048 mẫu để cuộn dạng sóng.
// Các mẫu được chuẩn hóa về chiều cao WAVE_H điểm ảnh.
module waveform_display (
    input  sys_clk,
    input  rst_n,
    input  pixel_clk,
    input  pixel_rst_n,

    // Đầu vào mẫu (một cho mỗi kênh, một cờ valid cho mỗi mẫu)
    input  [7:0] eeg_sample,   // UINT8 [0..255], biên độ ADC đã chuẩn hóa
    input        eeg_valid,
    input  [7:0] ecg_sample,
    input        ecg_valid,
    input  [7:0] emg_sample,
    input        emg_valid,

    // Vị trí VGA
    input  [11:0] hcount,
    input  [11:0] vcount,
    input         de,

    // Điểm ảnh đầu ra
    output reg [23:0] pixel_out
);

// Bố cục màn hình theo dõi y tế: 3 làn x 200 px ở hàng 0..599 (HUD nay chiếm 600..719).
localparam [11:0] WAVE_H  = 12'd200;   // chiều cao mỗi kênh
localparam [11:0] W_EEG_T = 12'd0;
localparam [11:0] W_ECG_T = 12'd200;
localparam [11:0] W_EMG_T = 12'd400;
localparam [11:0] WAVE_BOT = 12'd600;  // hàng đầu tiên ngay dưới vùng dạng sóng

localparam [23:0]
    COLOR_EEG  = 24'h00FF88,
    COLOR_ECG  = 24'hFF4444,
    COLOR_EMG  = 24'h4488FF,
    COLOR_BG   = 24'h111111,
    COLOR_GRID = 24'h222222;

// ── Bộ đệm dạng sóng (bộ đệm vòng sâu 2048, hiển thị đọc 1280 cột) ────────────
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

// Ghi: tăng con trỏ ghi và lưu mẫu (miền sys_clk)
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

// ── Sinh điểm ảnh (miền pixel_clk) ───────────────────────────────────────────
// Ánh xạ cột → chỉ số bộ đệm vòng
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

// ── Pipeline điểm ảnh (miền pixel_clk) ───────────────────────────────────────
// Sửa định thời: thiết kế cũ thực hiện đọc-BRAM → tỉ lệ ×220 → dịch dọc →
// so sánh tia → mux màu trong một chu kỳ (đường tệ nhất, slack -4.139 ns).
// Nay đã thành pipeline 5 tầng; các tín hiệu điều khiển VGA (hcount/vcount/de)
// được làm trễ đồng bộ để mỗi tầng so sánh dữ liệu đã căn theo thời gian. Kết quả
// hiển thị không đổi ngoài việc có thêm độ trễ pipeline cố định +3 điểm ảnh.
//
//   S0  đọc mẫu BRAM         -> eeg_val / ecg_val / emg_val
//   S1  tỉ lệ (× WAVE_H)      -> eeg_sy1 / ...           (1 phép nhân)
//   S2  dịch dải theo chiều dọc -> eeg_y2  / ...         (1 phép trừ)
//   S3  so sánh tia + lưới + nền -> draw_*3 / grid3 / bg3 (các phép so sánh)
//   S4  mux màu theo ưu tiên  -> pixel_out

// Đầu ra S0
reg [11:0] hcount_r,  vcount_r;
reg        de_r;
reg [7:0]  eeg_val, ecg_val, emg_val;

// Đầu ra S1 (biên độ đã tỉ lệ, 0..219)
reg [11:0] hcount_r1, vcount_r1;
reg        de_r1;
reg [11:0] eeg_sy1, ecg_sy1, emg_sy1;

// Đầu ra S2 (vị trí điểm ảnh theo chiều dọc trong dải kênh)
reg [11:0] hcount_r2, vcount_r2;
reg        de_r2;
reg [11:0] eeg_y2, ecg_y2, emg_y2;

// Đầu ra S3 (quyết định vẽ / lưới / nền đã được đưa vào thanh ghi)
reg        draw_eeg3, draw_ecg3, draw_emg3;
reg        grid3, bg3;

// ---- S0: đồng bộ CDC con trỏ Gray + đọc mẫu BRAM ----
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

// ---- S1: tỉ lệ [0..255] → [0..219] cho chiều cao kênh 220 px ----
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

// ---- S2: vị trí dọc = đỉnh_dải + WAVE_H - 1 - biên_độ_đã_tỉ_lệ ----
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

// ---- S3: so sánh tia (±2 px), lưới và nền (đều có thanh ghi) ----
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
wire grid_v_c = (hcount_r2[4:0] == 0);   // đường dọc mỗi 32 điểm ảnh
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

// ---- S4: mux màu theo ưu tiên ----
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
