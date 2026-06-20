`default_nettype none
// conv2d_engine.v - tích chập 2D dạng luồng với MAC được pipeline.
//
// Pha 5b: tách cây cộng 9 đầu vào thành một tầng tổng thành phần + một tầng
// tổng cuối. Đường tới hạn (critical path) trong Pha 5 chạy từ đầu ra bộ nhân
// DSP18 qua một chuỗi cộng sâu 9 tầng vào thanh ghi tích lũy (slack -22.4 ns ở
// 100 MHz). Pipeline mới nay có bố cục 5 tầng (DW) / 5 tầng (PW):
//
//   STG0  lắp ráp cửa sổ (DW) / chốt x_in (PW)
//   STG1  9 (DW) / C_IN*C_OUT (PW) phép nhân, đưa vào thanh ghi s2_prod
//   STG2  tổng thành phần: 3 nhóm <=3 tích → s2a_part[*][0..2]
//   STG3  tổng cuối + bias → s3_acc
//   STG4  dịch phải số học + bão hòa → y_out, y_valid
//
// Độ sâu tổ hợp mỗi tầng (ước lượng):
//   STG2 tổng thành phần:  2 mức cộng (tổng 3 đầu vào)
//   STG3 tổng cuối:        2 mức cộng (tổng 4 đầu vào kể cả bias)
//
// So với cây cộng 9 đầu vào một tầng trước đây (4 mức cộng)
// cộng thêm một mức cộng bias, cách tách này giảm một nửa chuỗi tổ hợp tệ nhất
// dẫn vào thanh ghi s3_acc.
//
// Giao diện không đổi: cùng cổng, cùng danh sách tham số, cùng tổng số xung
// y_valid H*W mỗi frame_start. Tổng độ trễ pipeline nay dài hơn thiết kế Pha 5
// 1 chu kỳ; cnn_top.v chấp nhận được vì timeout của nó rộng rãi và chỉ theo dõi
// số đếm.
//
// MODE = "DW"  : depthwise 3x3, zero-pad=1, C_OUT_EFF=C_IN, W_DEPTH=C_IN*9.
// MODE = "PW"  : pointwise 1x1, C_OUT_EFF=C_OUT, W_DEPTH=C_OUT*C_IN.
//                C_IN phải <= 9 (Tiny CNN hiện tại dùng 1 hoặc 8). Được kiểm tra
//                bằng $fatal lúc elaboration nếu vi phạm.
module conv2d_engine #(
    parameter MODE      = "DW",
    parameter C_IN      = 1,
    parameter C_OUT     = 1,
    parameter C_OUT_EFF = C_IN,
    parameter W_DEPTH   = C_IN*9,
    parameter H         = 32,
    parameter W         = 32,
    parameter SHIFT     = 7
)(
    input  wire                          sys_clk,
    input  wire                          rst_n,

    input  wire [(C_IN*16)-1:0]          x_in,
    input  wire                          x_valid,
    input  wire                          frame_start,

    input  wire [(W_DEPTH*8)-1:0]        w,
    input  wire [(C_OUT_EFF*32)-1:0]     b,

    output reg  [(C_OUT_EFF*16)-1:0]     y_out,
    output reg                           y_valid
);

localparam LINE_WIDTH = C_IN * 16;

function automatic signed [15:0] clip16;
    input signed [31:0] value;
    begin
        if (value > 32'sd127)       clip16 = 16'sd127;
        else if (value < -32'sd127) clip16 = -16'sd127;
        else                        clip16 = value[15:0];
    end
endfunction

// Mở rộng dấu (sign-extend) một tích 16 bit thành 32 bit (hàm trợ giúp cho các đường cây cộng).
function automatic signed [31:0] sext16to32;
    input signed [15:0] v;
    begin
        sext16to32 = {{16{v[15]}}, v};
    end
endfunction

generate
//=========================================================================
if (MODE == "DW") begin : g_dw
//=========================================================================
    // ---- 4 bộ đệm hàng luân phiên; đầu vào hàng R được ghi vào lb[R mod 4] ----
    // (Pha 5 đưa vào cơ chế luân phiên 4 bộ đệm để phá vỡ tranh chấp ghi đè giữa
    //  hàng R+3 và hàng R-1; không đổi trong Pha 5b.)
    reg [LINE_WIDTH-1:0] lb0 [0:W-1];
    reg [LINE_WIDTH-1:0] lb1 [0:W-1];
    reg [LINE_WIDTH-1:0] lb2 [0:W-1];
    reg [LINE_WIDTH-1:0] lb3 [0:W-1];

    // ---- Bộ theo dõi vị trí đầu vào/đầu ra ----
    reg [$clog2(H+2)-1:0] in_row;
    reg [$clog2(W+1)-1:0] in_col;
    reg [1:0]             in_buf;
    reg [$clog2(H+1)-1:0] out_row;
    reg [$clog2(W+1)-1:0] out_col;
    reg [1:0]             out_buf_top, out_buf_mid, out_buf_bot;

    wire window_row_ready =
        (out_row == H-1) ? (in_row >= H)
                         : (in_row > out_row + 1);
    wire output_done = (out_row >= H);

    // ---- Thanh ghi pipeline (DW) ----
    // Đầu ra STG-RA: địa chỉ đọc có thanh ghi + ảnh chụp chọn-bộ-đệm + các cờ.
    // Tách phép tính địa chỉ (out_col -> kẹp giá trị) khỏi việc đọc RAM phân tán
    // giúp giữ đường đọc hàng DW2 rộng trên một đường thanh-ghi-tới-thanh-ghi ngắn,
    // đây chính là yếu tố đạt định thời sys_clk.
    reg                          s0ra_valid;
    reg [$clog2(W+1)-1:0]        ra_col_m1, ra_col, ra_col_p1;
    reg [1:0]                    ra_buf_top, ra_buf_mid, ra_buf_bot;
    reg                          ra_f_row0, ra_f_col0, ra_f_colW, ra_f_rowH;

    // Đầu ra STG-RD (đưa các lần đọc line-RAM vào thanh ghi trước phép nhân):
    // các lần đọc thô bộ đệm hàng 3x3 + các cờ biên. Bộ mux-về-0 ở biên tạo nên
    // cửa sổ thực sự diễn ra một chu kỳ sau (STG0), nên đầu ra line-RAM được đưa
    // vào thanh ghi (rd_win) trước khi có thể tới bộ nhân.
    reg                          s0r_valid;
    reg [LINE_WIDTH-1:0]         rd_win [0:8];
    reg                          f_row0, f_col0, f_colW, f_rowH;

    // Đầu ra STG0 (cửa sổ đã lắp ráp, sẵn sàng cho phép nhân):
    reg                          s1_valid;
    reg [LINE_WIDTH-1:0]         s1_win [0:8];
    reg [(C_OUT_EFF*32)-1:0]     s1_b;

    // Đầu ra STG1 (các tích + bias):
    reg                          s2_valid;
    reg signed [15:0]            s2_prod [0:C_IN*9-1];
    reg signed [31:0]            s2_bias [0:C_IN-1];

    // Đầu ra STG2 MỚI (3 tổng thành phần mỗi tổng 3 tích, bias mang chuyển tiếp):
    reg                          s2a_valid;
    reg signed [31:0]            s2a_part [0:C_IN*3-1];
    reg signed [31:0]            s2a_bias [0:C_IN-1];

    // Đầu ra STG3 (tổng cuối kèm bias):
    reg                          s3_valid;
    reg signed [31:0]            s3_acc   [0:C_IN-1];

    integer di, dc;

    function [LINE_WIDTH-1:0] read_line;
        input [1:0]                buf_sel;
        input [$clog2(W+1)-1:0]    col;
        begin
            case (buf_sel)
                2'd0:    read_line = lb0[col];
                2'd1:    read_line = lb1[col];
                2'd2:    read_line = lb2[col];
                default: read_line = lb3[col];
            endcase
        end
    endfunction

    // Các cột đọc lân cận, được kẹp trong phạm vi. Vị trí ngoài biên được
    // đặt về 0 bởi các cờ biên trong STG0, nên việc kẹp ở đây chỉ để tránh đọc
    // một chỉ số ngoài phạm vi (giá trị bị loại bỏ).
    wire [$clog2(W+1)-1:0] rd_col_m1 = (out_col == 0)   ? out_col : (out_col - 1'b1);
    wire [$clog2(W+1)-1:0] rd_col_p1 = (out_col == W-1) ? out_col : (out_col + 1'b1);

    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) begin
            in_row  <= 0;
            in_col  <= 0;
            in_buf  <= 2'd0;
            out_row <= 0;
            out_col <= 0;
            out_buf_top <= 2'd3;
            out_buf_mid <= 2'd0;
            out_buf_bot <= 2'd1;
            s0ra_valid <= 1'b0;
            s0r_valid <= 1'b0;
            s1_valid  <= 1'b0;
            s2_valid  <= 1'b0;
            s2a_valid <= 1'b0;
            s3_valid  <= 1'b0;
            y_valid   <= 1'b0;
            y_out     <= {(C_OUT_EFF*16){1'b0}};
            s1_b      <= {(C_OUT_EFF*32){1'b0}};
            ra_col_m1 <= 0; ra_col <= 0; ra_col_p1 <= 0;
            ra_buf_top <= 2'd3; ra_buf_mid <= 2'd0; ra_buf_bot <= 2'd1;
            ra_f_row0 <= 1'b0; ra_f_col0 <= 1'b0; ra_f_colW <= 1'b0; ra_f_rowH <= 1'b0;
            f_row0 <= 1'b0; f_col0 <= 1'b0; f_colW <= 1'b0; f_rowH <= 1'b0;
            for (di = 0; di < 9; di = di+1) begin
                s1_win[di] <= {LINE_WIDTH{1'b0}};
                rd_win[di] <= {LINE_WIDTH{1'b0}};
            end
            for (di = 0; di < C_IN; di = di+1) begin
                s2_bias[di]  <= 32'd0;
                s2a_bias[di] <= 32'd0;
                s3_acc[di]   <= 32'd0;
            end
            for (di = 0; di < C_IN*9; di = di+1)
                s2_prod[di] <= 16'd0;
            for (di = 0; di < C_IN*3; di = di+1)
                s2a_part[di] <= 32'd0;
        end else begin
            // ---- Dịch cờ valid của pipeline ----
            s0ra_valid <= 1'b0;
            s0r_valid  <= s0ra_valid;
            s1_valid   <= s0r_valid;
            s2_valid   <= s1_valid;
            s2a_valid  <= s2_valid;
            s3_valid   <= s2a_valid;
            y_valid    <= s3_valid;

            if (frame_start) begin
                in_row  <= 0;
                in_col  <= 0;
                in_buf  <= 2'd0;
                out_row <= 0;
                out_col <= 0;
                out_buf_top <= 2'd3;
                out_buf_mid <= 2'd0;
                out_buf_bot <= 2'd1;
                s0ra_valid <= 1'b0;
                s0r_valid <= 1'b0;
                s1_valid  <= 1'b0;
                s2_valid  <= 1'b0;
                s2a_valid <= 1'b0;
                s3_valid  <= 1'b0;
                y_valid   <= 1'b0;
            end

            // ---- THU NHẬN ĐẦU VÀO ----
            if (x_valid && in_row < H) begin
                case (in_buf)
                    2'd0: lb0[in_col] <= x_in;
                    2'd1: lb1[in_col] <= x_in;
                    2'd2: lb2[in_col] <= x_in;
                    default: lb3[in_col] <= x_in;
                endcase

                if (in_col == W-1) begin
                    in_col <= 0;
                    in_row <= in_row + 1'b1;
                    in_buf <= in_buf + 1'b1;
                end else begin
                    in_col <= in_col + 1'b1;
                end
            end

            // ---- STG-RA: đưa địa chỉ đọc + chọn-bộ-đệm + cờ vào thanh ghi, tiến tới.
            // Chỉ out_col -> kẹp -> ghi thanh ghi ở đây (đường ngắn). Ảnh chụp bộ
            // đệm (ra_buf_*) đóng băng các bộ đệm trước khi luân phiên để lần đọc
            // một chu kỳ sau nhất quán qua các ranh giới hàng.
            if (window_row_ready && !output_done) begin
                ra_col_m1 <= rd_col_m1;
                ra_col    <= out_col;
                ra_col_p1 <= rd_col_p1;
                ra_buf_top <= out_buf_top;
                ra_buf_mid <= out_buf_mid;
                ra_buf_bot <= out_buf_bot;
                ra_f_row0 <= (out_row == 0);
                ra_f_col0 <= (out_col == 0);
                ra_f_colW <= (out_col == W-1);
                ra_f_rowH <= (out_row == H-1);

                s0ra_valid <= 1'b1;

                if (out_col == W-1) begin
                    out_col <= 0;
                    out_row <= out_row + 1'b1;
                    out_buf_top <= out_buf_mid;
                    out_buf_mid <= out_buf_bot;
                    out_buf_bot <= out_buf_bot + 1'b1;
                end else begin
                    out_col <= out_col + 1'b1;
                end
            end

            // ---- STG-RD: đọc cửa sổ thô 3x3 từ bộ đệm hàng theo địa chỉ đã ghi
            // vào thanh ghi (đọc RAM phân tán + mux bộ đệm 4:1 được cách ly ở chu
            // kỳ riêng). Việc đặt biên về 0 vẫn được hoãn sang STG0.
            if (s0ra_valid) begin
                rd_win[0] <= read_line(ra_buf_top, ra_col_m1);
                rd_win[1] <= read_line(ra_buf_top, ra_col);
                rd_win[2] <= read_line(ra_buf_top, ra_col_p1);
                rd_win[3] <= read_line(ra_buf_mid, ra_col_m1);
                rd_win[4] <= read_line(ra_buf_mid, ra_col);
                rd_win[5] <= read_line(ra_buf_mid, ra_col_p1);
                rd_win[6] <= read_line(ra_buf_bot, ra_col_m1);
                rd_win[7] <= read_line(ra_buf_bot, ra_col);
                rd_win[8] <= read_line(ra_buf_bot, ra_col_p1);

                f_row0 <= ra_f_row0;
                f_col0 <= ra_f_col0;
                f_colW <= ra_f_colW;
                f_rowH <= ra_f_rowH;
            end

            // ---- STG0: mux-về-0 ở biên lắp ráp cửa sổ từ rd_win ----
            // Tạo ra đúng các giá trị s1_win giống như cách lắp ráp một chu kỳ
            // trước đây; s1_valid theo sau s0r_valid qua phép dịch pipeline ở trên.
            if (s0r_valid) begin
                s1_win[0] <= (f_row0 || f_col0) ? {LINE_WIDTH{1'b0}} : rd_win[0];
                s1_win[1] <=  f_row0            ? {LINE_WIDTH{1'b0}} : rd_win[1];
                s1_win[2] <= (f_row0 || f_colW) ? {LINE_WIDTH{1'b0}} : rd_win[2];
                s1_win[3] <=  f_col0            ? {LINE_WIDTH{1'b0}} : rd_win[3];
                s1_win[4] <=                                            rd_win[4];
                s1_win[5] <=  f_colW            ? {LINE_WIDTH{1'b0}} : rd_win[5];
                s1_win[6] <= (f_rowH || f_col0) ? {LINE_WIDTH{1'b0}} : rd_win[6];
                s1_win[7] <=  f_rowH            ? {LINE_WIDTH{1'b0}} : rd_win[7];
                s1_win[8] <= (f_rowH || f_colW) ? {LINE_WIDTH{1'b0}} : rd_win[8];
                s1_b      <= b;
            end

            // ---- STG1: 9 tích mỗi kênh ----
            if (s1_valid) begin
                for (dc = 0; dc < C_IN; dc = dc+1) begin
                    s2_bias[dc] <= $signed(s1_b[(dc*32)+:32]);
                    s2_prod[dc*9 + 0] <=
                        $signed(s1_win[0][(dc*16)+:16]) * $signed(w[((dc*9 + 0)*8)+:8]);
                    s2_prod[dc*9 + 1] <=
                        $signed(s1_win[1][(dc*16)+:16]) * $signed(w[((dc*9 + 1)*8)+:8]);
                    s2_prod[dc*9 + 2] <=
                        $signed(s1_win[2][(dc*16)+:16]) * $signed(w[((dc*9 + 2)*8)+:8]);
                    s2_prod[dc*9 + 3] <=
                        $signed(s1_win[3][(dc*16)+:16]) * $signed(w[((dc*9 + 3)*8)+:8]);
                    s2_prod[dc*9 + 4] <=
                        $signed(s1_win[4][(dc*16)+:16]) * $signed(w[((dc*9 + 4)*8)+:8]);
                    s2_prod[dc*9 + 5] <=
                        $signed(s1_win[5][(dc*16)+:16]) * $signed(w[((dc*9 + 5)*8)+:8]);
                    s2_prod[dc*9 + 6] <=
                        $signed(s1_win[6][(dc*16)+:16]) * $signed(w[((dc*9 + 6)*8)+:8]);
                    s2_prod[dc*9 + 7] <=
                        $signed(s1_win[7][(dc*16)+:16]) * $signed(w[((dc*9 + 7)*8)+:8]);
                    s2_prod[dc*9 + 8] <=
                        $signed(s1_win[8][(dc*16)+:16]) * $signed(w[((dc*9 + 8)*8)+:8]);
                end
            end

            // ---- STG2 MỚI: 3 tổng thành phần mỗi tổng 3 tích + mang bias ----
            if (s2_valid) begin
                for (dc = 0; dc < C_IN; dc = dc+1) begin
                    s2a_bias[dc] <= s2_bias[dc];
                    s2a_part[dc*3 + 0] <=
                        sext16to32(s2_prod[dc*9 + 0]) +
                        sext16to32(s2_prod[dc*9 + 1]) +
                        sext16to32(s2_prod[dc*9 + 2]);
                    s2a_part[dc*3 + 1] <=
                        sext16to32(s2_prod[dc*9 + 3]) +
                        sext16to32(s2_prod[dc*9 + 4]) +
                        sext16to32(s2_prod[dc*9 + 5]);
                    s2a_part[dc*3 + 2] <=
                        sext16to32(s2_prod[dc*9 + 6]) +
                        sext16to32(s2_prod[dc*9 + 7]) +
                        sext16to32(s2_prod[dc*9 + 8]);
                end
            end

            // ---- STG3: cộng 3 tổng thành phần + bias ----
            if (s2a_valid) begin
                for (dc = 0; dc < C_IN; dc = dc+1) begin
                    s3_acc[dc] <= s2a_part[dc*3 + 0]
                                + s2a_part[dc*3 + 1]
                                + s2a_part[dc*3 + 2]
                                + s2a_bias[dc];
                end
            end

            // ---- STG4: dịch + clip ----
            if (s3_valid) begin
                for (dc = 0; dc < C_IN; dc = dc+1)
                    y_out[(dc*16)+:16] <= clip16(s3_acc[dc] >>> SHIFT);
            end
        end
    end

end // g_dw
//=========================================================================
else begin : g_pw
//=========================================================================
    // CHẾ ĐỘ PW: tích chập pointwise 1x1. C_IN phải <= 9 (được kiểm tra bên dưới).
    // Cùng pipeline 5 tầng như DW: chốt → nhân → tổng-thành-phần → tổng-cuối → dịch/clip.

    // Kiểm tra lúc elaboration: dừng với trạng thái lỗi (không phải $stop tương tác)
    // nếu bố cục tổng thành phần (tối đa 9 ô tích) bị vượt quá.
    initial begin
        if (C_IN > 9)
            $fatal(1, "conv2d_engine PW: C_IN=%0d > 9 not supported by partial-sum layout", C_IN);
    end

    // STG0 chốt dữ liệu
    reg                       s1_valid;
    reg [(C_IN*16)-1:0]       s1_x;
    reg [(W_DEPTH*8)-1:0]     s1_w;
    reg [(C_OUT_EFF*32)-1:0]  s1_b;

    // STG1 các tích + bias
    reg                       s2_valid;
    reg signed [15:0]         s2_prod [0:C_OUT_EFF*C_IN-1];
    reg signed [31:0]         s2_bias [0:C_OUT_EFF-1];

    // STG2 các tổng thành phần (3 tổng thành phần mỗi kênh đầu ra)
    reg                       s2a_valid;
    reg signed [31:0]         s2a_part [0:C_OUT_EFF*3-1];
    reg signed [31:0]         s2a_bias [0:C_OUT_EFF-1];

    // STG3 tổng cuối
    reg                       s3_valid;
    reg signed [31:0]         s3_acc   [0:C_OUT_EFF-1];

    integer pc, pi;

    // Với mỗi kênh đầu ra pc, mở rộng dấu product[pi] nếu pi < C_IN, ngược lại là 0.
    // Trả về giá trị thay thế 32 bit (mở rộng 0) khi chỉ số vượt quá C_IN.
    function automatic signed [31:0] pw_prod_or_zero;
        input integer pc_local;
        input integer pi_local;
        begin
            if (pi_local < C_IN)
                pw_prod_or_zero = {{16{s2_prod[pc_local*C_IN + pi_local][15]}},
                                   s2_prod[pc_local*C_IN + pi_local]};
            else
                pw_prod_or_zero = 32'sd0;
        end
    endfunction

    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_valid  <= 1'b0;
            s2_valid  <= 1'b0;
            s2a_valid <= 1'b0;
            s3_valid  <= 1'b0;
            y_valid   <= 1'b0;
            s1_x      <= {(C_IN*16){1'b0}};
            s1_w      <= {(W_DEPTH*8){1'b0}};
            s1_b      <= {(C_OUT_EFF*32){1'b0}};
            y_out     <= {(C_OUT_EFF*16){1'b0}};
            for (pc = 0; pc < C_OUT_EFF; pc = pc+1) begin
                s2_bias[pc]  <= 32'd0;
                s2a_bias[pc] <= 32'd0;
                s3_acc[pc]   <= 32'd0;
            end
            for (pc = 0; pc < C_OUT_EFF*C_IN; pc = pc+1)
                s2_prod[pc] <= 16'd0;
            for (pc = 0; pc < C_OUT_EFF*3; pc = pc+1)
                s2a_part[pc] <= 32'd0;
        end else begin
            s2_valid  <= s1_valid;
            s2a_valid <= s2_valid;
            s3_valid  <= s2a_valid;
            y_valid   <= s3_valid;

            // ---- STG0: chốt các đầu vào ----
            s1_valid <= x_valid;
            if (x_valid) begin
                s1_x <= x_in;
                s1_w <= w;
                s1_b <= b;
            end

            // ---- STG1: các phép nhân theo (co, ci) ----
            if (s1_valid) begin
                for (pc = 0; pc < C_OUT_EFF; pc = pc+1) begin
                    s2_bias[pc] <= $signed(s1_b[(pc*32)+:32]);
                    for (pi = 0; pi < C_IN; pi = pi+1) begin
                        s2_prod[pc*C_IN + pi] <=
                            $signed(s1_x[(pi*16)+:16]) *
                            $signed(s1_w[((pc*C_IN + pi)*8)+:8]);
                    end
                end
            end

            // ---- STG2 MỚI: 3 tổng thành phần mỗi kênh đầu ra + mang bias ----
            // Mỗi tổng thành phần cộng tối đa 3 ô tích; pw_prod_or_zero trả về 0
            // cho các chỉ số >= C_IN nên các ô không dùng được loại bỏ lúc elaboration.
            if (s2_valid) begin
                for (pc = 0; pc < C_OUT_EFF; pc = pc+1) begin
                    s2a_bias[pc] <= s2_bias[pc];
                    s2a_part[pc*3 + 0] <=
                        pw_prod_or_zero(pc, 0) +
                        pw_prod_or_zero(pc, 1) +
                        pw_prod_or_zero(pc, 2);
                    s2a_part[pc*3 + 1] <=
                        pw_prod_or_zero(pc, 3) +
                        pw_prod_or_zero(pc, 4) +
                        pw_prod_or_zero(pc, 5);
                    s2a_part[pc*3 + 2] <=
                        pw_prod_or_zero(pc, 6) +
                        pw_prod_or_zero(pc, 7) +
                        pw_prod_or_zero(pc, 8);
                end
            end

            // ---- STG3: cộng 3 tổng thành phần + bias ----
            if (s2a_valid) begin
                for (pc = 0; pc < C_OUT_EFF; pc = pc+1) begin
                    s3_acc[pc] <= s2a_part[pc*3 + 0]
                                + s2a_part[pc*3 + 1]
                                + s2a_part[pc*3 + 2]
                                + s2a_bias[pc];
                end
            end

            // ---- STG4: dịch + clip ----
            if (s3_valid) begin
                for (pc = 0; pc < C_OUT_EFF; pc = pc+1)
                    y_out[(pc*16)+:16] <= clip16(s3_acc[pc] >>> SHIFT);
            end
        end
    end

end // g_pw
endgenerate

endmodule

`default_nettype wire
