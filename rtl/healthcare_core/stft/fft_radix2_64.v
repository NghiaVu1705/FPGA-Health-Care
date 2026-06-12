// fft_radix2_64.v ↔ fft_radix2_64.py
// 64-point Radix-2 DIT FFT, in-place, 6 stages.
//
// Fixed-point:
//   Input: INT16[64] (windowed samples)
//   Twiddle: Q1.14 packed {Im[15:0], Re[15:0]} from pROM (32 entries)
//   Butterfly multiply: INT64 intermediate → >>> 14
//   Stage scaling: >>> 1 after each stage (block floating-point)
//   Output: INT32 Re[64] + Im[64]
//
// Bit-reversal: 6-bit reversal applied to input order (hardwired permutation).
// Latency: load 64 cycles + 6 × 32 butterflies × 4 pipeline cycles + copy-out.
//
// DSP18 usage: 4 multipliers per butterfly (re×re, im×im, re×im, im×re).
// Time-multiplexed: process 1 butterfly through a four-cycle pipeline.
module fft_radix2_64 (
    input  sys_clk,
    input  rst_n,

    // Input: 64 windowed INT16 samples, presented sequentially
    input  signed [15:0] x_in,
    input                x_valid,     // pulse 64 times to load frame
    input                frame_start, // pulse before first x_valid

    // Output: serial INT32 Re/Im, one bin per clock during copy-out
    output reg signed [31:0] re_out,
    output reg signed [31:0] im_out,
    output reg               bin_valid,
    output reg               frame_done,

    // pROM interface, driven by the parent IP instance
    output [4:0]             twiddle_addr_out,
    input  [31:0]            twiddle_data
);

// ── Twiddle ROM interface ─────────────────────────────────────────────────────
reg  [4:0]  twiddle_addr;

wire signed [15:0] w_re = $signed(twiddle_data[15:0]);
wire signed [15:0] w_im = $signed(twiddle_data[31:16]);

// ── Internal working buffer (64×32 = 2K bits each — infer as BSRAM) ──────────
(* syn_ramstyle = "block_ram" *) reg signed [31:0] buf_re [0:63];
(* syn_ramstyle = "block_ram" *) reg signed [31:0] buf_im [0:63];

// ── Bit-reversal LUT (6-bit reversal for N=64) ───────────────────────────────
function [5:0] bit_rev6;
    input [5:0] x;
    bit_rev6 = {x[0],x[1],x[2],x[3],x[4],x[5]};
endfunction

// ── State registers ───────────────────────────────────────────────────────────
reg [5:0] load_cnt;
reg       loading;
reg       do_fft;
reg [2:0] stage;
reg [5:0] group_i;
reg [5:0] pair_i;
reg [5:0] a_idx_r, b_idx_r;
reg signed [31:0] a_re_r, a_im_r, b_re_r, b_im_r;
reg [1:0] bfly_phase;
reg       copy_out;
reg [5:0] copy_cnt;

localparam [1:0]
    PH_FETCH = 2'd0,
    PH_MUL   = 2'd1,
    PH_SUM   = 2'd2,
    PH_WRITE = 2'd3;

// ── Butterfly parameters from small counters, then registered by PH_FETCH ────
wire [5:0] stride_w     = (6'd1 << stage);
wire [5:0] group_base_w = group_i << (stage + 3'd1);
wire [5:0] a_idx_w      = group_base_w + pair_i;
wire [5:0] b_idx_w      = a_idx_w + stride_w;
wire [5:0] tw_step_w    = (6'd32 >> stage);
wire [5:0] tw_k_w       = pair_i * tw_step_w;
wire [5:0] groups_w     = (6'd32 >> stage);

wire       last_pair_w  = (pair_i == (stride_w - 6'd1));
wire       last_group_w = (group_i == (groups_w - 6'd1));

// ── Butterfly math pipeline ──────────────────────────────────────────────────
reg signed [63:0] p_bre_wre_r;
reg signed [63:0] p_bim_wim_r;
reg signed [63:0] p_bre_wim_r;
reg signed [63:0] p_bim_wre_r;
reg signed [31:0] t_re_r;
reg signed [31:0] t_im_r;

wire signed [63:0] t_re_full_w = p_bre_wre_r - p_bim_wim_r;
wire signed [63:0] t_im_full_w = p_bre_wim_r + p_bim_wre_r;

// ── Unified always block — single driver for buf_re, buf_im, and all state ───
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

        // ── Load phase: fill buf with bit-reversed input ──────────────────
        if (loading && x_valid) begin
            buf_re[bit_rev6(load_cnt)] <= {{16{x_in[15]}}, x_in};
            buf_im[bit_rev6(load_cnt)] <= 32'd0;
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

        // ── Butterfly phase: fetch, multiply, sum, writeback ──────────────
        if (do_fft) begin
            case (bfly_phase)
                PH_FETCH: begin
                    twiddle_addr <= tw_k_w[4:0];
                    a_idx_r      <= a_idx_w;
                    b_idx_r      <= b_idx_w;
                    a_re_r       <= buf_re[a_idx_w];
                    a_im_r       <= buf_im[a_idx_w];
                    b_re_r       <= buf_re[b_idx_w];
                    b_im_r       <= buf_im[b_idx_w];
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
                    buf_re[a_idx_r] <= (a_re_r + t_re_r) >>> 1;
                    buf_im[a_idx_r] <= (a_im_r + t_im_r) >>> 1;
                    buf_re[b_idx_r] <= (a_re_r - t_re_r) >>> 1;
                    buf_im[b_idx_r] <= (a_im_r - t_im_r) >>> 1;
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

        // ── Copy output phase: stream buf to re_out/im_out ────────────────
        if (copy_out) begin
            re_out    <= buf_re[copy_cnt];
            im_out    <= buf_im[copy_cnt];
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
