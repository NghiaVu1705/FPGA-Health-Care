// maxpool_unit.v ↔ maxpool_unit.py
// 2×2 max pooling, stride 2, no overlap.
//
// Phase 5c: split the 4-input max compare into two stages.
//   Stage A (cycle when 2×2 block completes): compute pairwise max01 and max23,
//           register stage_a_max01 / stage_a_max23, fire stage_a_valid.
//   Stage B (next cycle):                     compute final max(max01,max23),
//           register y_out, assert y_valid.
//
// This breaks the previous 3-cascaded 16-bit compare chain (col_cnt → row_buf
// mux → 3 sequential 2-input maxes → y_out) into ≤1 compare per stage. Adds
// 1 cycle of latency.
//
// Verilog-2001 compatible:
//   - Flat packed bus for array ports (x_in, y_out)
//   - 1D row_buf (manual flattening of 2D: row_buf[col*C + ch])
//   - All temp vars at module level
module maxpool_unit #(
    parameter C = 8,
    parameter H = 32,
    parameter W = 32
)(
    input  sys_clk,
    input  rst_n,

    // Flat packed: x_in[(ch*16)+:16] = channel ch
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

// 1D row buffer (replaces 2D): index = col*C + ch
(* syn_ramstyle = "block_ram" *) reg [15:0] row_buf [0:W*C-1];

reg [15:0] prev_col [0:C-1];
reg        prev_col_valid;

// Phase 5c — stage-A partial maxes (one register set per channel).
reg [15:0] stage_a_max01 [0:C-1];
reg [15:0] stage_a_max23 [0:C-1];
reg        stage_a_valid;

// Verilog-2001: all temps at module level
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
        // ---- Stage-B output: drive y_valid only from stage_a_valid ----
        y_valid       <= stage_a_valid;
        // ---- Default deassert stage A so it pulses ----
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
                // Even row: buffer all channels into row_buf
                for (mp_c = 0; mp_c < C; mp_c = mp_c+1)
                    row_buf[col_cnt*C + mp_c] <= x_in[(mp_c*16)+:16];
            end else begin
                if (!col_cnt[0]) begin
                    // Even column of odd row — save for 2×2 block
                    for (mp_c = 0; mp_c < C; mp_c = mp_c+1)
                        prev_col[mp_c] <= x_in[(mp_c*16)+:16];
                    prev_col_valid <= 1'b1;
                end else if (prev_col_valid) begin
                    // Odd column: 2×2 block complete — Stage A fires this cycle.
                    // Compute pairwise max per channel and register; final max
                    // and y_valid are emitted next cycle by the stage-B block.
                    for (mp_c = 0; mp_c < C; mp_c = mp_c+1) begin
                        mp_m0 = row_buf[(col_cnt-1)*C + mp_c];  // even row, even col
                        mp_m1 = row_buf[ col_cnt   *C + mp_c];  // even row, odd col
                        mp_m2 = prev_col[mp_c];                 // odd row, even col
                        mp_m3 = x_in[(mp_c*16)+:16];            // odd row, odd col
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

        // ---- Stage B: final max of registered partials, drive y_out ----
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
