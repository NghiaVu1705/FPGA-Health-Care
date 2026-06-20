// fc_layer.v ↔ fc_layer.py
// Lớp kết nối đầy đủ C_IN→C_OUT, trọng số INT8, bias INT32, logit INT8.
//
// Pha 5e — pipeline phép MAC ở chu kỳ cuối.
//
// Trước Pha 5e, chu kỳ khi ci==C_IN-1 mang một chuỗi tổ hợp dài
// trong MỘT chu kỳ:
//      nhân → +acc → >>>dịch → clip16 → thanh ghi logits
// mà báo cáo tổng hợp của Pha 5d xác định là đường tệ nhất
// (u_fc/fc_w[15] → u_fc/logits[*], slack −6.314 ns ở 100 MHz).
//
// Pha 5e thay cấu trúc `running`/biến-tạm-blocking bằng một máy trạng thái
// gọn gàng, có thanh ghi giữa bộ tích lũy MAC, phép dịch số học,
// và bước clip+ghi. Pipeline argmax (Pha 5c) được giữ lại làm hai
// trạng thái cuối.
//
// Các trạng thái và công việc của từng trạng thái:
//
//   ST_IDLE   — chờ gap_valid.
//   ST_MAC    — một chu kỳ MAC: acc <= acc + w[co,ci]*gap_in[ci]; tăng ci.
//               Sau khi ci==C_IN-1, giá trị acc cuối được chốt tại đây và
//               quyền điều khiển chuyển sang ST_SHIFT.
//   ST_SHIFT  — đưa vào thanh ghi `shifted <= acc >>> shift`. Thêm 1 chu kỳ độ trễ.
//   ST_CLIP   — bão hòa `shifted` về ±127, ghi logits[(co*8)+:8]. Hoặc
//               bắt đầu neuron kế tiếp (quay về ST_MAC, nạp lại bias) hoặc khởi
//               động các tầng argmax.
//   ST_ARG_INIT/SCAN — argmax tuần tự trên C_OUT logit; khi hòa thì giữ
//                      chỉ số lớp nhỏ hơn.
//
// Tương đương về mặt toán học: logits và class_out tạo ra trùng khít từng bit
// với cách triển khai trước (acc được ghi vào thanh ghi tại đúng giá trị mà
// trước đây là đầu vào của phép dịch tổ hợp; dịch+clip sau đó cho ra
// cùng một byte). Khác biệt quan sát được duy nhất là +2 chu kỳ độ trễ
// mỗi neuron trong pipeline FC.
module fc_layer #(
    parameter C_IN  = 16,
    parameter C_OUT = 3,
    parameter CLASS_BITS = (C_OUT <= 2) ? 1 : $clog2(C_OUT)
)(
    input  sys_clk,
    input  rst_n,

    input  [(C_IN*16)-1:0] gap_in,     // INT16 từ GlobalMaxPool
    input         gap_valid,
    input  [4:0]  shift,               // combined_shift từ scale_rom[4]

    // Trọng số/bias được cnn_top nạp sẵn từ BSRAM
    input  [(C_OUT*C_IN*8)-1:0] w,      // INT8 [C_OUT, C_IN] theo thứ tự hàng (row-major)
    input  [(C_OUT*32)-1:0]     b,      // bias INT32

    output reg [(C_OUT*8)-1:0] logits,  // đầu ra INT8
    output reg               logits_valid,
    output reg [CLASS_BITS-1:0] class_out          // argmax
);

localparam [2:0]
    ST_IDLE     = 3'd0,
    ST_FETCH    = 3'd1,
    ST_MAC      = 3'd2,
    ST_SHIFT    = 3'd3,
    ST_CLIP     = 3'd4,
    ST_ARG_INIT = 3'd5,
    ST_ARG_SCAN = 3'd6;

reg [2:0]             state;
reg [$clog2(C_IN):0]  ci;
reg [$clog2(C_OUT):0] co;
reg signed [31:0]     acc;
reg signed [31:0]     shifted;
reg [$clog2(C_OUT):0] arg_idx;
reg signed [7:0]      arg_best;
reg [CLASS_BITS-1:0]  arg_best_idx;

// Sửa định thời: việc chọn toán hạng từ bus trọng số phẳng (C_OUT*C_IN*8) bit
// (768 bit khi NUM_CLASSES=6) cộng với việc chọn kích hoạt được đưa vào thanh ghi ở
// ST_FETCH *trước* phép nhân ở ST_MAC, thay vì đưa mux động thẳng vào DSP+bộ cộng.
// Điều này làm vòng lặp MAC mất 2 chu kỳ/tap nhưng giữ phép tính trùng khít từng bit
// (cùng tích, cùng thứ tự tích lũy).
reg signed [7:0]   w_sel;   // trọng số được chọn  cho (co, ci)
reg signed [15:0]  a_sel;   // kích hoạt được chọn cho ci

// Tích MAC tổ hợp từ các toán hạng *đã đưa vào thanh ghi*. Giữ dưới dạng wire để
// suy luận DSP18 của bộ tổng hợp không mơ hồ; bộ tích lũy có thanh ghi
// là `acc` (chính là thứ được đẩy sang ST_SHIFT).
wire signed [15:0] mac_prod = $signed(w_sel) * $signed(a_sel);

always @(posedge sys_clk or negedge rst_n) begin
    if (!rst_n) begin
        state         <= ST_IDLE;
        ci            <= 0;
        co            <= 0;
        acc           <= 32'sd0;
        shifted       <= 32'sd0;
        w_sel         <= 8'sd0;
        a_sel         <= 16'sd0;
        logits        <= {(C_OUT*8){1'b0}};
        logits_valid  <= 1'b0;
        class_out     <= {CLASS_BITS{1'b0}};
        arg_idx       <= 0;
        arg_best      <= 8'sd0;
        arg_best_idx  <= {CLASS_BITS{1'b0}};
    end else begin
        logits_valid <= 1'b0;

        case (state)
            ST_IDLE: begin
                if (gap_valid) begin
                    state <= ST_FETCH;
                    ci    <= 0;
                    co    <= 0;
                    acc   <= $signed(b[31:0]);
                end
            end

            ST_FETCH: begin
                // Đưa trọng số + kích hoạt đã chọn vào thanh ghi. Đây là mux toán
                // hạng 768 bit dài; cách ly nó sau w_sel/a_sel giúp đường đầu vào
                // của bộ nhân ngắn lại.
                w_sel <= $signed(w[((co*C_IN + ci)*8)+:8]);
                a_sel <= $signed(gap_in[(ci*16)+:16]);
                state <= ST_MAC;
            end

            ST_MAC: begin
                // Tích lũy một tích (từ các toán hạng đã ghi vào thanh ghi). Lần
                // tích lũy cuối được chốt tại đây (không dịch/clip trong cùng chu
                // kỳ), nên chuỗi tổ hợp tệ nhất kết thúc ở `acc`.
                acc <= acc + {{16{mac_prod[15]}}, mac_prod};
                if (ci == C_IN - 1) begin
                    state <= ST_SHIFT;
                end else begin
                    ci    <= ci + 1'b1;
                    state <= ST_FETCH;
                end
            end

            ST_SHIFT: begin
                // Một tầng thanh ghi cách ly bộ dịch barrel khỏi
                // bộ cộng đang nuôi `acc`.
                shifted <= acc >>> shift;
                state   <= ST_CLIP;
            end

            ST_CLIP: begin
                // Bão hòa về INT8 và ghi logit của neuron. Sau đó hoặc bắt đầu
                // neuron kế tiếp hoặc bàn giao cho argmax.
                if (shifted > 32'sd127)
                    logits[(co*8)+:8] <= 8'sd127;
                else if (shifted < -32'sd127)
                    logits[(co*8)+:8] <= -8'sd127;
                else
                    logits[(co*8)+:8] <= shifted[7:0];

                if (co == C_OUT - 1) begin
                    state <= ST_ARG_INIT;
                end else begin
                    co    <= co + 1'b1;
                    ci    <= 0;
                    acc   <= $signed(b[((co + 1)*32)+:32]);
                    state <= ST_FETCH;
                end
            end

            ST_ARG_INIT: begin
                arg_best     <= $signed(logits[7:0]);
                arg_best_idx <= {CLASS_BITS{1'b0}};
                arg_idx      <= 1;
                state        <= ST_ARG_SCAN;
            end

            ST_ARG_SCAN: begin
                if (arg_idx < C_OUT) begin
                    if ($signed(logits[(arg_idx*8)+:8]) > arg_best) begin
                        arg_best     <= $signed(logits[(arg_idx*8)+:8]);
                        arg_best_idx <= arg_idx[CLASS_BITS-1:0];
                    end

                    if (arg_idx == C_OUT - 1) begin
                        class_out <= ($signed(logits[(arg_idx*8)+:8]) > arg_best)
                                   ? arg_idx[CLASS_BITS-1:0]
                                   : arg_best_idx;
                        logits_valid <= 1'b1;
                        state        <= ST_IDLE;
                    end else begin
                        arg_idx <= arg_idx + 1'b1;
                    end
                end else begin
                    class_out    <= arg_best_idx;
                    logits_valid <= 1'b1;
                    state        <= ST_IDLE;
                end
            end

            default: state <= ST_IDLE;
        endcase
    end
end

endmodule
