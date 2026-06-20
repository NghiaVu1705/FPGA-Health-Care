// global_maxpool_unit.v ↔ global_maxpool_unit.py
// Lấy giá trị lớn nhất trên tất cả vị trí không gian H×W theo từng kênh.
// Đầu vào: nối tiếp 8×8×16 (sau block2 + maxpool2)
// Đầu ra: INT16[16] — giá trị lớn nhất mỗi kênh
//
// RTL: cây rút gọn bằng bộ so sánh, không cần dịch bit (GlobalMaxPool, không phải GlobalAvgPool).
// CNN_GAP_SHIFT_LEGACY KHÔNG được dùng ở đây.
module global_maxpool_unit #(
    parameter C = 16,
    parameter H = 8,
    parameter W = 8
)(
    input  sys_clk,
    input  rst_n,

    input  [(C*16)-1:0] x_in,   // INT16 một vị trí không gian, tất cả các kênh
    input         x_valid,
    input         frame_start,

    output reg [(C*16)-1:0] gap_out,  // giá trị lớn nhất mỗi kênh
    output reg        gap_valid
);

localparam TOTAL = H * W;
reg [$clog2(TOTAL):0] pixel_cnt;
integer c;
reg [15:0] x_ch;
reg [15:0] max_ch;

always @(posedge sys_clk or negedge rst_n) begin
    if (!rst_n) begin
        pixel_cnt <= 0;
        gap_valid <= 1'b0;
        gap_out <= 0;
    end else begin
        gap_valid <= 1'b0;

        if (frame_start) begin
            pixel_cnt <= 0;
            gap_out <= 0;
        end

        if (x_valid) begin
            for (c = 0; c < C; c = c+1) begin
                x_ch = x_in[(c*16)+:16];
                max_ch = gap_out[(c*16)+:16];
                if (x_ch > max_ch)
                    gap_out[(c*16)+:16] <= x_ch;
            end
            if (pixel_cnt == TOTAL - 1) begin
                gap_valid <= 1'b1;
                pixel_cnt <= 0;
            end else begin
                pixel_cnt <= pixel_cnt + 1'b1;
            end
        end
    end
end

endmodule
