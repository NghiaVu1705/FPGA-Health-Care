// maxpool_unit.v ↔ maxpool_unit.py
// Max pooling 2×2, bước nhảy (stride) 2, không chồng lấn.
//
// Pha 5c: tách phép so sánh max 4 đầu vào thành hai tầng.
//   Tầng A (chu kỳ khi khối 2×2 hoàn tất): tính max theo cặp max01 và max23,
//           đưa vào thanh ghi stage_a_max01 / stage_a_max23, phát stage_a_valid.
//   Tầng B (chu kỳ kế tiếp):               tính max cuối max(max01,max23),
//           đưa y_out vào thanh ghi, bật y_valid.
//
// Điều này phá vỡ chuỗi so sánh 16 bit nối tiếp 3 tầng trước đây (col_cnt → mux
// row_buf → 3 phép max 2 đầu vào tuần tự → y_out) thành ≤1 phép so sánh mỗi tầng.
// Thêm 1 chu kỳ độ trễ.
//
// Tương thích Verilog-2001:
//   - Bus đóng gói phẳng (flat packed) cho các cổng mảng (x_in, y_out)
//   - row_buf 1 chiều (làm phẳng thủ công từ 2 chiều: row_buf[col*C + ch])
//   - Tất cả biến tạm đặt ở mức module
module maxpool_unit #(
    parameter C = 8,
    parameter H = 32,
    parameter W = 32
)(
    input  sys_clk,
    input  rst_n,

    // Đóng gói phẳng: x_in[(ch*16)+:16] = kênh ch
    input  [(C*16)-1:0] x_in,
    input               x_valid,
    input               frame_start,

    output reg [(C*16)-1:0] y_out,
    output reg              y_valid
);

localparam H_OUT = H / 2;
localparam W_OUT = W / 2;

reg [$clog2(H)-1:0] row_cnt;
reg [$clog2(W)-1:0] col_cnt;

// Bộ đệm hàng 1 chiều (thay cho 2 chiều): chỉ số = col*C + ch
(* syn_ramstyle = "block_ram" *) reg [15:0] row_buf [0:W*C-1];

reg [15:0] prev_col [0:C-1];
reg        prev_col_valid;

// Pha 5c — các max thành phần của tầng A (một bộ thanh ghi cho mỗi kênh).
reg [15:0] stage_a_max01 [0:C-1];
reg [15:0] stage_a_max23 [0:C-1];
reg        stage_a_valid;

// Verilog-2001: tất cả biến tạm ở mức module
integer    mp_c;
reg [15:0] mp_m0, mp_m1, mp_m2, mp_m3;

integer    mp_init;

always @(posedge sys_clk or negedge rst_n) begin
    if (!rst_n) begin
        row_cnt        <= 0;
        col_cnt        <= 0;
        prev_col_valid <= 1'b0;
        stage_a_valid  <= 1'b0;
        y_valid        <= 1'b0;
        y_out          <= {(C*16){1'b0}};
        for (mp_init = 0; mp_init < C; mp_init = mp_init+1) begin
            stage_a_max01[mp_init] <= 16'd0;
            stage_a_max23[mp_init] <= 16'd0;
        end
    end else begin
        // ---- Đầu ra tầng B: điều khiển y_valid chỉ từ stage_a_valid ----
        y_valid       <= stage_a_valid;
        // ---- Mặc định hạ tầng A xuống để nó tạo xung ----
        stage_a_valid <= 1'b0;

        if (frame_start) begin
            row_cnt        <= 0;
            col_cnt        <= 0;
            prev_col_valid <= 1'b0;
            stage_a_valid  <= 1'b0;
            y_valid        <= 1'b0;
        end

        if (x_valid) begin
            if (!row_cnt[0]) begin
                // Hàng chẵn: đệm tất cả các kênh vào row_buf
                for (mp_c = 0; mp_c < C; mp_c = mp_c+1)
                    row_buf[col_cnt*C + mp_c] <= x_in[(mp_c*16)+:16];
            end else begin
                if (!col_cnt[0]) begin
                    // Cột chẵn của hàng lẻ — lưu lại cho khối 2×2
                    for (mp_c = 0; mp_c < C; mp_c = mp_c+1)
                        prev_col[mp_c] <= x_in[(mp_c*16)+:16];
                    prev_col_valid <= 1'b1;
                end else if (prev_col_valid) begin
                    // Cột lẻ: khối 2×2 hoàn tất — Tầng A kích hoạt ở chu kỳ này.
                    // Tính max theo cặp cho mỗi kênh rồi đưa vào thanh ghi; max cuối
                    // và y_valid được tầng B phát ra ở chu kỳ kế tiếp.
                    for (mp_c = 0; mp_c < C; mp_c = mp_c+1) begin
                        mp_m0 = row_buf[(col_cnt-1)*C + mp_c];  // hàng chẵn, cột chẵn
                        mp_m1 = row_buf[ col_cnt   *C + mp_c];  // hàng chẵn, cột lẻ
                        mp_m2 = prev_col[mp_c];                 // hàng lẻ, cột chẵn
                        mp_m3 = x_in[(mp_c*16)+:16];            // hàng lẻ, cột lẻ
                        stage_a_max01[mp_c] <= (mp_m0 >= mp_m1) ? mp_m0 : mp_m1;
                        stage_a_max23[mp_c] <= (mp_m2 >= mp_m3) ? mp_m2 : mp_m3;
                    end
                    stage_a_valid  <= 1'b1;
                    prev_col_valid <= 1'b0;
                end
            end

            if (col_cnt == W-1) begin
                col_cnt <= 0;
                if (row_cnt == H-1) row_cnt <= 0;
                else row_cnt <= row_cnt + 1'b1;
            end else begin
                col_cnt <= col_cnt + 1'b1;
            end
        end

        // ---- Tầng B: max cuối của các giá trị thành phần đã ghi, điều khiển y_out ----
        if (stage_a_valid) begin
            for (mp_c = 0; mp_c < C; mp_c = mp_c+1)
                y_out[(mp_c*16)+:16] <=
                    (stage_a_max01[mp_c] >= stage_a_max23[mp_c])
                        ? stage_a_max01[mp_c]
                        : stage_a_max23[mp_c];
        end
    end
end

endmodule
