// global_maxpool_unit.v ↔ global_maxpool_unit.py
// Max over all H×W spatial positions per channel.
// Input: serial 8×8×16 (after block2 + maxpool2)
// Output: INT16[16] — max per channel
//
// RTL: comparator reduce-tree, no shift needed (GlobalMaxPool, not GlobalAvgPool).
// CNN_GAP_SHIFT_LEGACY is NOT used here.
module global_maxpool_unit #(
    parameter C = 16,
    parameter H = 8,
    parameter W = 8
)(
    input  sys_clk,
    input  rst_n,

    input  [(C*16)-1:0] x_in,   // INT16 one spatial position, all channels
    input         x_valid,
    input         frame_start,

    output reg [(C*16)-1:0] gap_out,  // max per channel
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
