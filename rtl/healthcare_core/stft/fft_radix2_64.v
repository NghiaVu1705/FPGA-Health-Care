// fft_radix2_64.v ↔ fft_radix2_64.py
// FFT 64 điểm Radix-2 DIT, tại chỗ (in-place), 6 tầng.
//
// Dấu phẩy tĩnh (fixed-point):
//   Đầu vào: INT16[64] (các mẫu đã áp cửa sổ)
//   Twiddle: Q1.14 đóng gói {Im[15:0], Re[15:0]} từ pROM (32 phần tử)
//   Phép nhân butterfly: trung gian INT64 → >>> 14
//   Tỉ lệ theo tầng: >>> 1 sau mỗi tầng (block floating-point)
//   Đầu ra: INT32 Re[64] + Im[64]
//
// Đảo bit: đảo 6 bit áp lên thứ tự đầu vào (hoán vị nối cứng).
// Độ trễ: nạp 64 chu kỳ + 6 × 32 butterfly × 4 chu kỳ pipeline + sao chép ra.
//
// Sử dụng DSP18: 4 bộ nhân mỗi butterfly (re×re, im×im, re×im, im×re).
// Ghép kênh theo thời gian: xử lý 1 butterfly qua pipeline bốn chu kỳ.
module fft_radix2_64 (
    input  sys_clk,
    input  rst_n,

    // Đầu vào: 64 mẫu INT16 đã áp cửa sổ, đưa vào tuần tự
    input  signed [15:0] x_in,
    input                x_valid,     // phát xung 64 lần để nạp khung
    input                frame_start, // phát xung trước x_valid đầu tiên

    // Đầu ra: Re/Im INT32 nối tiếp, một bin mỗi chu kỳ trong lúc sao chép ra
    output reg signed [31:0] re_out,
    output reg signed [31:0] im_out,
    output reg               bin_valid,
    output reg               frame_done,

    // Giao diện pROM, được điều khiển bởi thực thể IP cha
    output [4:0]             twiddle_addr_out,
    input  [31:0]            twiddle_data
);

// ── Giao diện ROM twiddle ─────────────────────────────────────────────────────
reg  [4:0]  twiddle_addr;

wire signed [15:0] w_re = $signed(twiddle_data[15:0]);
wire signed [15:0] w_im = $signed(twiddle_data[31:16]);

// ── Bộ đệm làm việc nội bộ (mỗi cái 64×32 = 2K bit — suy luận thành BSRAM) ────
// Butterfly đọc đồng thời 2 địa chỉ (a_idx, b_idx) VÀ ghi đồng thời 2 địa chỉ,
// nên một BSRAM (SDPB: 1 đọc + 1 ghi) không đủ cổng → trước đây bị suy luận
// thành thanh ghi LUT (regfile): phình CLS và đẩy a_idx_w[5]/b_idx_w[5] lên mạng
// clock toàn cục (PRIMARY/LW 8/8) → nghẽn định tuyến (262 net không nối được).
// Khắc phục: nhân đôi bộ đệm thành 2 bản sao giống hệt — cổng đọc 'a' đọc bản
// _a, cổng đọc 'b' đọc bản _b — và tuần tự hoá 2 lần ghi qua 2 pha
// (PH_WRITE/PH_WRITE2). Mỗi mảng khi đó chỉ còn 1 địa chỉ đọc + 1 địa chỉ ghi
// mỗi chu kỳ ⇒ suy luận sạch thành SDPB (BSRAM còn dư nhiều: ~22%).
(* syn_ramstyle = "block_ram" *) reg signed [31:0] buf_re_a [0:63];
(* syn_ramstyle = "block_ram" *) reg signed [31:0] buf_re_b [0:63];
(* syn_ramstyle = "block_ram" *) reg signed [31:0] buf_im_a [0:63];
(* syn_ramstyle = "block_ram" *) reg signed [31:0] buf_im_b [0:63];

// ── LUT đảo bit (đảo 6 bit cho N=64) ─────────────────────────────────────────
function [5:0] bit_rev6;
    input [5:0] x;
    bit_rev6 = {x[0],x[1],x[2],x[3],x[4],x[5]};
endfunction

// ── Thanh ghi trạng thái ──────────────────────────────────────────────────────
reg [5:0] load_cnt;
reg       loading;
reg       do_fft;
reg [2:0] stage;
reg [5:0] group_i;
reg [5:0] pair_i;
reg [5:0] a_idx_r, b_idx_r;
reg signed [31:0] a_re_r, a_im_r, b_re_r, b_im_r;
reg [2:0] bfly_phase;
reg       copy_out;
reg [5:0] copy_cnt;

localparam [2:0]
    PH_FETCH  = 3'd0,
    PH_MUL    = 3'd1,
    PH_SUM    = 3'd2,
    PH_WRITE  = 3'd3,   // ghi nhánh a (cùng dữ liệu vào cả 2 bản sao)
    PH_WRITE2 = 3'd4;   // ghi nhánh b + cập nhật bộ đếm butterfly

// ── Tham số butterfly từ các bộ đếm nhỏ, rồi đưa vào thanh ghi bởi PH_FETCH ───
wire [5:0] stride_w     = (6'd1 << stage);
wire [5:0] group_base_w = group_i << (stage + 3'd1);
wire [5:0] a_idx_w      = group_base_w + pair_i;
wire [5:0] b_idx_w      = a_idx_w + stride_w;
wire [5:0] tw_step_w    = (6'd32 >> stage);
wire [5:0] tw_k_w       = pair_i * tw_step_w;
wire [5:0] groups_w     = (6'd32 >> stage);

wire       last_pair_w  = (pair_i == (stride_w - 6'd1));
wire       last_group_w = (group_i == (groups_w - 6'd1));

// ── Pipeline tính toán butterfly ─────────────────────────────────────────────
reg signed [63:0] p_bre_wre_r;
reg signed [63:0] p_bim_wim_r;
reg signed [63:0] p_bre_wim_r;
reg signed [63:0] p_bim_wre_r;
reg signed [31:0] t_re_r;
reg signed [31:0] t_im_r;

wire signed [63:0] t_re_full_w = p_bre_wre_r - p_bim_wim_r;
wire signed [63:0] t_im_full_w = p_bre_wim_r + p_bim_wre_r;

// ── Khối always hợp nhất — driver duy nhất cho buf_re_a/_b, buf_im_a/_b và mọi trạng thái ─
always @(posedge sys_clk) begin : fft_core
    if (!rst_n) begin
        load_cnt     <= 6'd0;
        loading      <= 1'b0;
        do_fft       <= 1'b0;
        stage        <= 3'd0;
        group_i      <= 6'd0;
        pair_i       <= 6'd0;
        bfly_phase   <= PH_FETCH;
        twiddle_addr <= 5'd0;
        a_idx_r      <= 6'd0;
        b_idx_r      <= 6'd0;
        a_re_r       <= 32'd0;
        a_im_r       <= 32'd0;
        b_re_r       <= 32'd0;
        b_im_r       <= 32'd0;
        copy_out     <= 1'b0;
        copy_cnt     <= 6'd0;
        re_out       <= 32'd0;
        im_out       <= 32'd0;
        bin_valid    <= 1'b0;
        frame_done   <= 1'b0;
        p_bre_wre_r  <= 64'sd0;
        p_bim_wim_r  <= 64'sd0;
        p_bre_wim_r  <= 64'sd0;
        p_bim_wre_r  <= 64'sd0;
        t_re_r       <= 32'sd0;
        t_im_r       <= 32'sd0;
    end else begin
        frame_done <= 1'b0;
        bin_valid  <= 1'b0;

        if (frame_start) begin
            loading  <= 1'b1;
            load_cnt <= 6'd0;
            do_fft   <= 1'b0;
            copy_out <= 1'b0;
        end

        // ── Pha nạp: lấp buf bằng đầu vào đã đảo bit ──────────────────────
        if (loading && x_valid) begin
            buf_re_a[bit_rev6(load_cnt)] <= {{16{x_in[15]}}, x_in};
            buf_re_b[bit_rev6(load_cnt)] <= {{16{x_in[15]}}, x_in};
            buf_im_a[bit_rev6(load_cnt)] <= 32'd0;
            buf_im_b[bit_rev6(load_cnt)] <= 32'd0;
            if (load_cnt == 6'd63) begin
                loading  <= 1'b0;
                do_fft   <= 1'b1;
                stage    <= 3'd0;
                group_i  <= 6'd0;
                pair_i   <= 6'd0;
                bfly_phase <= PH_FETCH;
            end
            load_cnt <= load_cnt + 6'd1;
        end

        // ── Pha butterfly: nạp, nhân, cộng, ghi lại ───────────────────────
        if (do_fft) begin
            case (bfly_phase)
                PH_FETCH: begin
                    twiddle_addr <= tw_k_w[4:0];
                    a_idx_r      <= a_idx_w;
                    b_idx_r      <= b_idx_w;
                    a_re_r       <= buf_re_a[a_idx_w];
                    a_im_r       <= buf_im_a[a_idx_w];
                    b_re_r       <= buf_re_b[b_idx_w];
                    b_im_r       <= buf_im_b[b_idx_w];
                    bfly_phase   <= PH_MUL;
                end

                PH_MUL: begin
                    p_bre_wre_r <= $signed(b_re_r) * $signed(w_re);
                    p_bim_wim_r <= $signed(b_im_r) * $signed(w_im);
                    p_bre_wim_r <= $signed(b_re_r) * $signed(w_im);
                    p_bim_wre_r <= $signed(b_im_r) * $signed(w_re);
                    bfly_phase  <= PH_SUM;
                end

                PH_SUM: begin
                    t_re_r      <= t_re_full_w[45:14];
                    t_im_r      <= t_im_full_w[45:14];
                    bfly_phase  <= PH_WRITE;
                end

                PH_WRITE: begin
                    // Nhánh a → ghi cùng giá trị vào CẢ HAI bản sao (giữ đồng bộ)
                    buf_re_a[a_idx_r] <= (a_re_r + t_re_r) >>> 1;
                    buf_re_b[a_idx_r] <= (a_re_r + t_re_r) >>> 1;
                    buf_im_a[a_idx_r] <= (a_im_r + t_im_r) >>> 1;
                    buf_im_b[a_idx_r] <= (a_im_r + t_im_r) >>> 1;
                    bfly_phase <= PH_WRITE2;
                end

                PH_WRITE2: begin
                    // Nhánh b → ghi cùng giá trị vào CẢ HAI bản sao (giữ đồng bộ)
                    buf_re_a[b_idx_r] <= (a_re_r - t_re_r) >>> 1;
                    buf_re_b[b_idx_r] <= (a_re_r - t_re_r) >>> 1;
                    buf_im_a[b_idx_r] <= (a_im_r - t_im_r) >>> 1;
                    buf_im_b[b_idx_r] <= (a_im_r - t_im_r) >>> 1;
                    bfly_phase <= PH_FETCH;

                    if (last_pair_w) begin
                        pair_i <= 6'd0;
                        if (last_group_w) begin
                            group_i <= 6'd0;
                            if (stage == 3'd5) begin
                                do_fft   <= 1'b0;
                                copy_out <= 1'b1;
                                copy_cnt <= 6'd0;
                            end else begin
                                stage <= stage + 3'd1;
                            end
                        end else begin
                            group_i <= group_i + 6'd1;
                        end
                    end else begin
                        pair_i <= pair_i + 6'd1;
                    end
                end
            endcase
        end

        // ── Pha sao chép đầu ra: truyền buf ra re_out/im_out ──────────────
        if (copy_out) begin
            re_out    <= buf_re_a[copy_cnt];
            im_out    <= buf_im_a[copy_cnt];
            bin_valid <= 1'b1;
            if (copy_cnt == 6'd63) begin
                copy_out   <= 1'b0;
                frame_done <= 1'b1;
            end else begin
                copy_cnt <= copy_cnt + 1'b1;
            end
        end
    end
end

assign twiddle_addr_out = twiddle_addr;

endmodule
