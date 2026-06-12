// magnitude_calc.v ↔ magnitude_calc.py
// Alpha-max approximation: mag ≈ max(|Re|, |Im|) + (min(|Re|, |Im|) >> 1)
// Error ≤ 11.8% vs true sqrt — acceptable for INT8 (≤15 quantization levels).
//
// Input:  INT32 Re[32] + Im[32] (positive-frequency bins 0..31)
// Output: flattened UINT8[32] normalized to [0, 127], bin k at [k*8 +: 8].
//
// Normalization:
//   shift = floor(log2(max_mag / 127))   (via leading-zero count)
//   out[k] = clip(mag[k] >> shift, 0, 127)
//
// Latency: 2 passes over 32 bins (1 for max, 1 for normalize) = ~70 cycles.
module magnitude_calc (
    input  sys_clk,
    input  rst_n,

    // Input: 32 bins, presented sequentially after fft frame_done
    input  signed [31:0] re_in,
    input  signed [31:0] im_in,
    input                bin_valid,   // pulse 32 times (bins 0..31)
    input                frame_start,

    // Output: 32 UINT8 magnitudes, flattened for Verilog-2001 synthesis
    output reg [255:0] mag_out,
    output reg       frame_done
);

// ── Pass 1: compute alpha-max magnitudes and find global max ──────────────────

reg [31:0] mag_buf [0:31];   // magnitude for each bin (unsigned 32-bit)
reg [31:0] max_mag;
reg [4:0]  bin_cnt;
reg        pass1_done;

wire [31:0] abs_re = re_in[31] ? (~re_in + 1'b1) : re_in;  // |Re|
wire [31:0] abs_im = im_in[31] ? (~im_in + 1'b1) : im_in;  // |Im|

// alpha-max: max(a,b) + min(a,b)/2
wire [31:0] mx  = (abs_re >= abs_im) ? abs_re : abs_im;
wire [31:0] mn  = (abs_re >= abs_im) ? abs_im : abs_re;
wire [31:0] mag = mx + (mn >> 1);

always @(posedge sys_clk or negedge rst_n) begin
    if (!rst_n) begin
        max_mag    <= 32'd0;
        bin_cnt    <= 5'd0;
        pass1_done <= 1'b0;
    end else begin
        pass1_done <= 1'b0;

        if (frame_start) begin
            max_mag    <= 32'd0;
            bin_cnt    <= 5'd0;
        end

        if (bin_valid) begin
            mag_buf[bin_cnt] <= mag;
            if (mag > max_mag) max_mag <= mag;
            if (bin_cnt == 5'd31) begin
                pass1_done <= 1'b1;
                bin_cnt    <= 5'd0;
            end else begin
                bin_cnt <= bin_cnt + 1'b1;
            end
        end
    end
end

// ── Compute normalization shift (leading-zero count over 32-bit value) ───────
// shift = max(0, floor(log2(max_mag)) - floor(log2(127)))
//       = max(0, (31 - LZC(max_mag)) - 6)
//       because log2(127) ≈ 6.99 → floor = 6

function [4:0] lzc32;
    input [31:0] x;
    integer k;
    begin
        lzc32 = 5'd31;
        for (k = 30; k >= 0; k = k-1)
            if (x[k]) lzc32 = 5'd31 - k;
    end
endfunction

// ── Pass 2: normalize and output ──────────────────────────────────────────────

reg [4:0] norm_shift;
reg [4:0] norm_cnt;
reg       normalizing;
// Verilog-2001: local vars must be at module level, not in unnamed blocks
reg [4:0]  msb_pos_r;
reg [31:0] mag_shifted_r;
integer j_mag;

always @(posedge sys_clk or negedge rst_n) begin
    if (!rst_n) begin
        norm_shift  <= 5'd0;
        norm_cnt    <= 5'd0;
        normalizing <= 1'b0;
        frame_done  <= 1'b0;
        mag_out     <= 256'd0;
    end else begin
        frame_done <= 1'b0;
        if (pass1_done) begin
            if (max_mag == 32'd0) begin
                // All-zero frame — skip normalization
                normalizing <= 1'b0;
                frame_done  <= 1'b1;
                for (j_mag = 0; j_mag < 32; j_mag = j_mag + 1)
                    mag_out[(j_mag*8) +: 8] <= 8'd0;
            end else begin
                // shift = (31 - LZC) - 6, clamped to >= 0
                msb_pos_r  = 5'd31 - lzc32(max_mag);
                norm_shift <= (msb_pos_r >= 5'd6) ? (msb_pos_r - 5'd6) : 5'd0;
                normalizing <= 1'b1;
                norm_cnt    <= 5'd0;
            end
        end

        if (normalizing) begin
            // clip(mag_buf >> norm_shift, 0, 127)
            mag_shifted_r = mag_buf[norm_cnt] >> norm_shift;
            mag_out[(norm_cnt*8) +: 8] <= (mag_shifted_r > 32'd127) ? 8'd127 : mag_shifted_r[7:0];
            if (norm_cnt == 5'd31) begin
                normalizing <= 1'b0;
                frame_done  <= 1'b1;
            end else begin
                norm_cnt <= norm_cnt + 1'b1;
            end
        end
    end
end

endmodule
