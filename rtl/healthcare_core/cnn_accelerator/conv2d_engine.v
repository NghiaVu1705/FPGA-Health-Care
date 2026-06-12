`default_nettype none
// conv2d_engine.v - streaming 2D convolution with pipelined MAC.
//
// Phase 5b: split the 9-input add-tree into a partial-sum stage + a final-sum
// stage. Critical path in Phase 5 ran from a DSP18 multiplier output through
// a 9-deep adder chain into the accumulator register (slack -22.4 ns at 100
// MHz). The new pipeline now has a 5-stage layout (DW) / 5-stage (PW):
//
//   STG0  window assembly (DW) / capture x_in (PW)
//   STG1  9 (DW) / C_IN*C_OUT (PW) multiplications, registered as s2_prod
//   STG2  partial sums: 3 groups of <=3 products → s2a_part[*][0..2]
//   STG3  final sum + bias → s3_acc
//   STG4  arithmetic shift right + saturate → y_out, y_valid
//
// Per-stage combinational depth (estimated):
//   STG2 partial sum:  2 adder levels (3-input sum)
//   STG3 final sum:    2 adder levels (4-input sum incl. bias)
//
// Compared with the previous single-stage 9-input add-tree (4 adder levels)
// plus a 1-level bias add, this split halves the worst-case combinational
// chain feeding the s3_acc register.
//
// Interface unchanged: same ports, same parameter list, same total H*W
// y_valid pulses per frame_start. Total pipeline latency is now 1 cycle
// longer than the Phase 5 design; cnn_top.v tolerates because its timeout
// is generous and it only watches counts.
//
// MODE = "DW"  : 3x3 depthwise, zero-pad=1, C_OUT_EFF=C_IN, W_DEPTH=C_IN*9.
// MODE = "PW"  : 1x1 pointwise, C_OUT_EFF=C_OUT, W_DEPTH=C_OUT*C_IN.
//                C_IN must be <= 9 (current Tiny CNN uses 1 or 8). Verified
//                by an elaboration $error if violated.
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

// Sign-extend a 16-bit product to 32 bits (helper for the add-tree paths).
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
    // ---- 4 rolling line buffers; row R input is written to lb[R mod 4] ----
    // (Phase 5 introduced 4-buffer rolling to break the row R+3 vs row R-1
    //  overwrite race; unchanged in Phase 5b.)
    reg [LINE_WIDTH-1:0] lb0 [0:W-1];
    reg [LINE_WIDTH-1:0] lb1 [0:W-1];
    reg [LINE_WIDTH-1:0] lb2 [0:W-1];
    reg [LINE_WIDTH-1:0] lb3 [0:W-1];

    // ---- Input/output position trackers ----
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

    // ---- Pipeline registers (DW) ----
    // STG-RA output: registered read address + buffer-select snapshot + flags.
    // Splitting the address compute (out_col -> clamp) from the distributed-RAM
    // read keeps the wide DW2 line read on a short register-to-register path,
    // which is what closes sys_clk timing.
    reg                          s0ra_valid;
    reg [$clog2(W+1)-1:0]        ra_col_m1, ra_col, ra_col_p1;
    reg [1:0]                    ra_buf_top, ra_buf_mid, ra_buf_bot;
    reg                          ra_f_row0, ra_f_col0, ra_f_colW, ra_f_rowH;

    // STG-RD output (register the line-RAM reads before the multiply):
    // raw 3x3 line-buffer reads + boundary flags. The boundary zero-mux that
    // forms the actual window happens one cycle later (STG0), so the line-RAM
    // output is registered (rd_win) before it can reach the multiplier.
    reg                          s0r_valid;
    reg [LINE_WIDTH-1:0]         rd_win [0:8];
    reg                          f_row0, f_col0, f_colW, f_rowH;

    // STG0 output (window assembled, ready for multiply):
    reg                          s1_valid;
    reg [LINE_WIDTH-1:0]         s1_win [0:8];
    reg [(C_OUT_EFF*32)-1:0]     s1_b;

    // STG1 output (products + bias):
    reg                          s2_valid;
    reg signed [15:0]            s2_prod [0:C_IN*9-1];
    reg signed [31:0]            s2_bias [0:C_IN-1];

    // STG2 output NEW (3 partial sums of 3 products each, bias carried forward):
    reg                          s2a_valid;
    reg signed [31:0]            s2a_part [0:C_IN*3-1];
    reg signed [31:0]            s2a_bias [0:C_IN-1];

    // STG3 output (final sum with bias):
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

    // Neighbour read columns, clamped in-range. Out-of-band positions are
    // zeroed by the boundary flags in STG0, so clamping only avoids reading an
    // out-of-range index here (value is discarded).
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
            // ---- Pipeline valid shift ----
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

            // ---- INPUT INGEST ----
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

            // ---- STG-RA: register read address + buffer-select + flags, advance.
            // Only out_col -> clamp -> register here (short path). The buffer
            // snapshot (ra_buf_*) freezes the pre-rotation buffers so the read one
            // cycle later is coherent across row boundaries.
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

            // ---- STG-RD: read the raw 3x3 line-buffer window from the registered
            // address (distributed-RAM read + 4:1 buffer mux isolated on its own
            // cycle). Boundary zeroing is still deferred to STG0.
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

            // ---- STG0: boundary zero-mux assembles the window from rd_win ----
            // Produces exactly the same s1_win values as the previous single-cycle
            // assembly; s1_valid follows s0r_valid via the pipeline shift above.
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

            // ---- STG1: 9 products per channel ----
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

            // ---- STG2 NEW: 3 partial sums of 3 products each + bias carry ----
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

            // ---- STG3: sum 3 partials + bias ----
            if (s2a_valid) begin
                for (dc = 0; dc < C_IN; dc = dc+1) begin
                    s3_acc[dc] <= s2a_part[dc*3 + 0]
                                + s2a_part[dc*3 + 1]
                                + s2a_part[dc*3 + 2]
                                + s2a_bias[dc];
                end
            end

            // ---- STG4: shift + clip ----
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
    // PW MODE: 1x1 pointwise convolution. C_IN must be <= 9 (asserted below).
    // Same 5-stage pipeline as DW: capture → mult → partial-sum → final-sum → shift/clip.

    // Elaboration-time check
    initial begin
        if (C_IN > 9) begin
            $display("FATAL conv2d_engine PW: C_IN=%0d > 9 not supported by partial-sum layout", C_IN);
            $stop;
        end
    end

    // STG0 capture
    reg                       s1_valid;
    reg [(C_IN*16)-1:0]       s1_x;
    reg [(W_DEPTH*8)-1:0]     s1_w;
    reg [(C_OUT_EFF*32)-1:0]  s1_b;

    // STG1 products + bias
    reg                       s2_valid;
    reg signed [15:0]         s2_prod [0:C_OUT_EFF*C_IN-1];
    reg signed [31:0]         s2_bias [0:C_OUT_EFF-1];

    // STG2 partial sums (3 partials per output channel)
    reg                       s2a_valid;
    reg signed [31:0]         s2a_part [0:C_OUT_EFF*3-1];
    reg signed [31:0]         s2a_bias [0:C_OUT_EFF-1];

    // STG3 final sum
    reg                       s3_valid;
    reg signed [31:0]         s3_acc   [0:C_OUT_EFF-1];

    integer pc, pi;

    // For each output channel pc, sign-extend product[pi] if pi < C_IN else 0.
    // Returns 32-bit zero-extended placeholder when index is beyond C_IN.
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

            // ---- STG0: capture inputs ----
            s1_valid <= x_valid;
            if (x_valid) begin
                s1_x <= x_in;
                s1_w <= w;
                s1_b <= b;
            end

            // ---- STG1: per-(co, ci) multiplications ----
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

            // ---- STG2 NEW: 3 partial sums per output channel + bias carry ----
            // Each partial sums up to 3 product slots; pw_prod_or_zero returns 0
            // for indices >= C_IN so unused slots fold out at elaboration time.
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

            // ---- STG3: sum 3 partials + bias ----
            if (s2a_valid) begin
                for (pc = 0; pc < C_OUT_EFF; pc = pc+1) begin
                    s3_acc[pc] <= s2a_part[pc*3 + 0]
                                + s2a_part[pc*3 + 1]
                                + s2a_part[pc*3 + 2]
                                + s2a_bias[pc];
                end
            end

            // ---- STG4: shift + clip ----
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
