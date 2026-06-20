// cnn_top.v ↔ cnn_top.py
// Bộ điều phối suy luận CNN. Nạp trọng số INT8 từ BSRAM khi khởi động,
// sau đó chạy toàn bộ pipeline trên mỗi spectrogram 32x32.
// LƯU Ý: default NUM_CLASSES=3 cho các top cũ (top.v, biomed_full_system.v).
//   shared-AI (biomed_shared_ai_system.v) override NUM_CLASSES=6.
module cnn_top #(
    parameter NUM_CLASSES = 3,
    parameter CLASS_BITS = (NUM_CLASSES <= 2) ? 1 : $clog2(NUM_CLASSES)
)(
    input  sys_clk,
    input  rst_n,

    // Đầu vào spectrogram: 32x32 UINT8, theo thứ tự hàng (row-major), một byte mỗi chu kỳ
    input  [7:0]  spec_in,
    input         spec_valid,
    input         spec_start,

    // Đầu ra phân loại
    output reg [CLASS_BITS-1:0] class_out,
    output reg       class_valid,

    // Cổng đọc BSRAM (512x8, độ trễ đọc 1 chu kỳ)
    output reg [8:0] bsram_addr,
    input      [7:0] bsram_data
);

// ── Thanh ghi trọng số/bias (nạp từ BSRAM khi khởi động) ─────────────────────
reg signed [7:0]  dw1_w [0:8];
reg signed [7:0]  pw1_w [0:7];
reg signed [7:0]  dw2_w [0:71];
reg signed [7:0]  pw2_w [0:127];
reg signed [7:0]  fc_w  [0:(NUM_CLASSES*16)-1];
reg signed [31:0] dw1_b;
reg signed [31:0] pw1_b [0:7];
reg signed [31:0] dw2_b [0:7];
reg signed [31:0] pw2_b [0:15];
reg signed [31:0] fc_b  [0:NUM_CLASSES-1];
reg [4:0]         shift_dw1, shift_pw1, shift_dw2, shift_pw2, shift_fc;

localparam integer OFF_FC_W = 224;
localparam integer FC_W_BYTES = NUM_CLASSES * 16;
localparam integer OFF_BIAS = OFF_FC_W + FC_W_BYTES;
localparam integer FIXED_BIAS_COUNT = 33;
localparam integer OFF_SHIFT = OFF_BIAS + (FIXED_BIAS_COUNT + NUM_CLASSES) * 4;
// +1 so với số byte: việc đọc cache trọng số nay ĐÃ ĐƯA VÀO THANH GHI (BSRAM), nên
// đường nạp mất 2 chu kỳ (bsram_addr có thanh ghi + đọc cache có thanh ghi). load_addr
// phải đạt OFF_SHIFT+6 cho byte cuối (shift_fc) vì bsram_prev=load_addr-2.
localparam integer LOAD_LAST = OFF_SHIFT + 5;

// ── Máy trạng thái (FSM) mức trên cùng ───────────────────────────────────────
localparam [2:0]
    ST_LOAD   = 3'd0,
    ST_READY  = 3'd1,
    ST_SPEC   = 3'd2,
    ST_INFER  = 3'd3,
    ST_DONE   = 3'd4;

reg [2:0] state;
reg [8:0] load_addr;
reg [9:0] spec_cnt;

// Bộ đệm spectrogram và kích hoạt (activation)
(* syn_ramstyle = "block_ram" *) reg [7:0] spec_buf [0:1023];

// Các biến tạm của FSM nạp (load)
integer    cnn_i;
reg [8:0]  bsram_prev;
reg [8:0]  bias_base;
reg [8:0]  bias_delta;
reg [5:0]  bias_idx;
reg [1:0]  b_byte;
reg [31:0] b_asm;

// ── Bus trọng số/bias đóng gói cho cổng module con kiểu Verilog-2001 ──────────
wire [71:0]   dw1_w_flat;
wire [31:0]   dw1_b_flat;
wire [63:0]   pw1_w_flat;
wire [255:0]  pw1_b_flat;
wire [575:0]  dw2_w_flat;
wire [255:0]  dw2_b_flat;
wire [1023:0] pw2_w_flat;
wire [511:0]  pw2_b_flat;
wire [(NUM_CLASSES*16*8)-1:0] fc_w_flat;
wire [(NUM_CLASSES*32)-1:0]   fc_b_flat;

assign dw1_b_flat = dw1_b;

genvar gk;
generate
    for (gk = 0; gk < 9; gk = gk+1) begin : gen_dw1_w
        assign dw1_w_flat[(gk*8)+:8] = dw1_w[gk];
    end
    for (gk = 0; gk < 8; gk = gk+1) begin : gen_pw1
        assign pw1_w_flat[(gk*8)+:8] = pw1_w[gk];
        assign pw1_b_flat[(gk*32)+:32] = pw1_b[gk];
    end
    for (gk = 0; gk < 72; gk = gk+1) begin : gen_dw2_w
        assign dw2_w_flat[(gk*8)+:8] = dw2_w[gk];
    end
    for (gk = 0; gk < 8; gk = gk+1) begin : gen_dw2_b
        assign dw2_b_flat[(gk*32)+:32] = dw2_b[gk];
    end
    for (gk = 0; gk < 128; gk = gk+1) begin : gen_pw2_w
        assign pw2_w_flat[(gk*8)+:8] = pw2_w[gk];
    end
    for (gk = 0; gk < 16; gk = gk+1) begin : gen_pw2_b
        assign pw2_b_flat[(gk*32)+:32] = pw2_b[gk];
    end
    for (gk = 0; gk < NUM_CLASSES*16; gk = gk+1) begin : gen_fc_w
        assign fc_w_flat[(gk*8)+:8] = fc_w[gk];
    end
    for (gk = 0; gk < NUM_CLASSES; gk = gk+1) begin : gen_fc_b
        assign fc_b_flat[(gk*32)+:32] = fc_b[gk];
    end
endgenerate

// ── Điều khiển các tầng suy luận ─────────────────────────────────────────────
reg        infer_done;
reg [3:0]  infer_stage;
reg        stage_fs;
reg        s0_valid;
reg [15:0] s0_x;

reg [9:0] pix1_in_cnt;
reg       stage0_feed_done;
reg       mp1_seen;
reg       mp2_seen;

wire      mp1_frame_start_w;
wire      mp2_frame_start_w;

// ── DW1 → ReLU → PW1 → ReLU → MaxPool1 (khối 1) ─────────────────────────────
wire [15:0] dw1_y;
wire        dw1_v;
conv2d_engine #(
    .MODE("DW"), .C_IN(1), .C_OUT(1), .C_OUT_EFF(1), .W_DEPTH(9),
    .H(32), .W(32), .SHIFT(7)
) u_dw1 (
    .sys_clk(sys_clk), .rst_n(rst_n),
    .x_in(s0_x), .x_valid(s0_valid), .frame_start(stage_fs && infer_stage == 4'd0),
    .w(dw1_w_flat), .b(dw1_b_flat),
    .y_out(dw1_y), .y_valid(dw1_v)
);

wire [15:0] dw1_r;
relu_unit u_r_dw1 (.x_in(dw1_y), .y_out(dw1_r));

wire [127:0] pw1_y;
wire         pw1_v;
conv2d_engine #(
    .MODE("PW"), .C_IN(1), .C_OUT(8), .C_OUT_EFF(8), .W_DEPTH(8),
    .H(32), .W(32), .SHIFT(7)
) u_pw1 (
    .sys_clk(sys_clk), .rst_n(rst_n),
    .x_in(dw1_r), .x_valid(dw1_v), .frame_start(stage_fs && infer_stage == 4'd0),
    .w(pw1_w_flat), .b(pw1_b_flat),
    .y_out(pw1_y), .y_valid(pw1_v)
);

wire [127:0] pw1_r;
genvar ri;
generate
    for (ri = 0; ri < 8; ri = ri+1) begin : gen_relu_pw1
        relu_unit u_r_pw1i (
            .x_in(pw1_y[(ri*16)+:16]),
            .y_out(pw1_r[(ri*16)+:16])
        );
    end
endgenerate

wire [127:0] mp1_y;
wire         mp1_v;
maxpool_unit #(.C(8), .H(32), .W(32)) u_mp1 (
    .sys_clk(sys_clk), .rst_n(rst_n),
    .x_in(pw1_r), .x_valid(pw1_v), .frame_start(stage_fs && infer_stage == 4'd0),
    .y_out(mp1_y), .y_valid(mp1_v)
);

assign mp1_frame_start_w = mp1_v && !mp1_seen;

// ── DW2 → ReLU → PW2 → ReLU → MaxPool2 (khối 2) ─────────────────────────────
wire [127:0] dw2_y;
wire         dw2_v;
conv2d_engine #(
    .MODE("DW"), .C_IN(8), .C_OUT(8), .C_OUT_EFF(8), .W_DEPTH(72),
    .H(16), .W(16), .SHIFT(7)
) u_dw2 (
    .sys_clk(sys_clk), .rst_n(rst_n),
    .x_in(mp1_y), .x_valid(mp1_v), .frame_start(mp1_frame_start_w),
    .w(dw2_w_flat), .b(dw2_b_flat),
    .y_out(dw2_y), .y_valid(dw2_v)
);

wire [127:0] dw2_r;
generate
    for (ri = 0; ri < 8; ri = ri+1) begin : gen_relu_dw2
        relu_unit u_r_dw2i (
            .x_in(dw2_y[(ri*16)+:16]),
            .y_out(dw2_r[(ri*16)+:16])
        );
    end
endgenerate

wire [255:0] pw2_y;
wire         pw2_v;
conv2d_engine #(
    .MODE("PW"), .C_IN(8), .C_OUT(16), .C_OUT_EFF(16), .W_DEPTH(128),
    .H(16), .W(16), .SHIFT(6)
) u_pw2 (
    .sys_clk(sys_clk), .rst_n(rst_n),
    .x_in(dw2_r), .x_valid(dw2_v), .frame_start(mp1_frame_start_w),
    .w(pw2_w_flat), .b(pw2_b_flat),
    .y_out(pw2_y), .y_valid(pw2_v)
);

wire [255:0] pw2_r;
generate
    for (ri = 0; ri < 16; ri = ri+1) begin : gen_relu_pw2
        relu_unit u_r_pw2i (
            .x_in(pw2_y[(ri*16)+:16]),
            .y_out(pw2_r[(ri*16)+:16])
        );
    end
endgenerate

wire [255:0] mp2_y;
wire         mp2_v;
maxpool_unit #(.C(16), .H(16), .W(16)) u_mp2 (
    .sys_clk(sys_clk), .rst_n(rst_n),
    .x_in(pw2_r), .x_valid(pw2_v), .frame_start(mp1_frame_start_w),
    .y_out(mp2_y), .y_valid(mp2_v)
);

assign mp2_frame_start_w = mp2_v && !mp2_seen;

// ── GlobalMaxPool và FC ──────────────────────────────────────────────────────
wire [255:0] gap_y_w;
wire         gap_v_w;
global_maxpool_unit #(.C(16), .H(8), .W(8)) u_gap (
    .sys_clk(sys_clk), .rst_n(rst_n),
    .x_in(mp2_y), .x_valid(mp2_v), .frame_start(mp2_frame_start_w),
    .gap_out(gap_y_w), .gap_valid(gap_v_w)
);

wire [(NUM_CLASSES*8)-1:0] fc_logits_w;
wire        fc_lv;
wire [CLASS_BITS-1:0] fc_class_w;
fc_layer #(.C_IN(16), .C_OUT(NUM_CLASSES), .CLASS_BITS(CLASS_BITS)) u_fc (
    .sys_clk(sys_clk), .rst_n(rst_n),
    .gap_in(gap_y_w), .gap_valid(gap_v_w), .shift(shift_fc),
    .w(fc_w_flat), .b(fc_b_flat),
    .logits(fc_logits_w), .logits_valid(fc_lv), .class_out(fc_class_w)
);

// ── FSM nạp (load) ───────────────────────────────────────────────────────────
always @(posedge sys_clk or negedge rst_n) begin
    if (!rst_n) begin
        state       <= ST_LOAD;
        load_addr   <= 9'd0;
        class_valid <= 1'b0;
        bsram_addr  <= 9'd0;
        b_byte      <= 2'd0;
        b_asm       <= 32'd0;
        spec_cnt    <= 10'd0;
    end else begin
        class_valid <= 1'b0;

        case (state)
            ST_LOAD: begin
                bsram_addr <= load_addr;
                // Đọc cache có thanh ghi => độ trễ 2 chu kỳ: bsram_data ở chu kỳ này
                // là cache[load_addr-2]. (Trước đây là load_addr-1 với cache bất đồng bộ cũ.)
                if (load_addr > 9'd1) begin
                    bsram_prev = load_addr - 9'd2;
                    if      (bsram_prev <= 9'd8)                               dw1_w[bsram_prev[3:0]]             <= $signed(bsram_data);
                    else if (bsram_prev >= 9'd16  && bsram_prev <= 9'd23)      pw1_w[bsram_prev[2:0]]             <= $signed(bsram_data);
                    else if (bsram_prev >= 9'd24  && bsram_prev <= 9'd95)      dw2_w[bsram_prev - 9'd24]          <= $signed(bsram_data);
                    else if (bsram_prev >= 9'd96  && bsram_prev <= 9'd223)     pw2_w[bsram_prev - 9'd96]          <= $signed(bsram_data);
                    else if (bsram_prev >= OFF_FC_W && bsram_prev < OFF_BIAS)  fc_w [bsram_prev - OFF_FC_W]       <= $signed(bsram_data);
                    else if (bsram_prev >= OFF_BIAS && bsram_prev < OFF_SHIFT) begin
                        b_asm <= {bsram_data, b_asm[31:8]};
                        if (b_byte == 2'd3) begin
                            bias_base = bsram_prev - 9'd3;
                            if (bias_base == OFF_BIAS) begin
                                dw1_b <= {bsram_data, b_asm[31:8]};
                            end else if (bias_base >= OFF_BIAS + 4 && bias_base < OFF_BIAS + 36) begin
                                bias_delta = bias_base - (OFF_BIAS + 4);
                                bias_idx = bias_delta[7:2];
                                pw1_b[bias_idx] <= {bsram_data, b_asm[31:8]};
                            end else if (bias_base >= OFF_BIAS + 36 && bias_base < OFF_BIAS + 68) begin
                                bias_delta = bias_base - (OFF_BIAS + 36);
                                bias_idx = bias_delta[7:2];
                                dw2_b[bias_idx] <= {bsram_data, b_asm[31:8]};
                            end else if (bias_base >= OFF_BIAS + 68 && bias_base < OFF_BIAS + 132) begin
                                bias_delta = bias_base - (OFF_BIAS + 68);
                                bias_idx = bias_delta[7:2];
                                pw2_b[bias_idx] <= {bsram_data, b_asm[31:8]};
                            end else if (bias_base >= OFF_BIAS + 132 && bias_base < OFF_SHIFT) begin
                                bias_delta = bias_base - (OFF_BIAS + 132);
                                bias_idx = bias_delta[7:2];
                                fc_b[bias_idx] <= {bsram_data, b_asm[31:8]};
                            end
                        end
                        b_byte <= b_byte + 1'b1;
                    end else if (bsram_prev == OFF_SHIFT + 0) shift_dw1 <= bsram_data[4:0];
                    else if (bsram_prev == OFF_SHIFT + 1) shift_pw1 <= bsram_data[4:0];
                    else if (bsram_prev == OFF_SHIFT + 2) shift_dw2 <= bsram_data[4:0];
                    else if (bsram_prev == OFF_SHIFT + 3) shift_pw2 <= bsram_data[4:0];
                    else if (bsram_prev == OFF_SHIFT + 4) begin
                        shift_fc <= bsram_data[4:0];
                        state    <= ST_READY;
                    end
                end
                if (load_addr <= LOAD_LAST)
                    load_addr <= load_addr + 1'b1;
            end

            ST_READY: begin
                if (spec_start) begin
                    state <= ST_SPEC;
                    if (spec_valid) begin
                        spec_buf[10'd0] <= spec_in;
                        spec_cnt <= 10'd1;
                    end else begin
                        spec_cnt <= 10'd0;
                    end
                end
            end

            ST_SPEC: begin
                if (spec_valid) begin
                    spec_buf[spec_cnt] <= spec_in;
                    if (spec_cnt == 10'd1023) begin
                        state <= ST_INFER;
                        spec_cnt <= 10'd0;
                    end else begin
                        spec_cnt <= spec_cnt + 1'b1;
                    end
                end
            end

            ST_INFER: begin
                if (infer_done)
                    state <= ST_DONE;
            end

            ST_DONE: begin
                class_valid <= 1'b1;
                state <= ST_READY;
            end

            default: begin
                state    <= ST_LOAD;
                spec_cnt <= 10'd0;
            end
        endcase
    end
end

// ── FSM con cho suy luận ─────────────────────────────────────────────────────
always @(posedge sys_clk or negedge rst_n) begin
    if (!rst_n) begin
        infer_done <= 1'b0;
        infer_stage <= 4'd0;
        pix1_in_cnt <= 10'd0;
        stage0_feed_done <= 1'b0;
        mp1_seen <= 1'b0;
        mp2_seen <= 1'b0;
        s0_valid <= 1'b0;
        stage_fs <= 1'b0;
        s0_x <= 16'd0;
        class_out <= {CLASS_BITS{1'b0}};
    end else begin
        infer_done <= 1'b0;
        s0_valid <= 1'b0;
        stage_fs <= 1'b0;

        if (state != ST_INFER) begin
            infer_stage <= 4'd0;
            pix1_in_cnt <= 10'd0;
            stage0_feed_done <= 1'b0;
            mp1_seen <= 1'b0;
            mp2_seen <= 1'b0;
        end else begin
            if (!stage0_feed_done) begin
                if (pix1_in_cnt == 10'd0)
                    stage_fs <= 1'b1;
                s0_x <= {8'd0, spec_buf[pix1_in_cnt]};
                s0_valid <= 1'b1;
                if (pix1_in_cnt == 10'd1023) begin
                    pix1_in_cnt <= 10'd0;
                    stage0_feed_done <= 1'b1;
                end else begin
                    pix1_in_cnt <= pix1_in_cnt + 1'b1;
                end
            end

            if (mp1_v) begin
                mp1_seen <= 1'b1;
            end

            if (mp2_v) begin
                mp2_seen <= 1'b1;
            end

            if (fc_lv) begin
                class_out <= fc_class_w;
                infer_done <= 1'b1;
            end
        end
    end
end

endmodule
