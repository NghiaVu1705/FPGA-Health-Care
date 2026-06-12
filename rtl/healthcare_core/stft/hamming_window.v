// hamming_window.v ↔ hamming_window.py
// Apply Hamming window to a 64-sample frame.
// Coefficients stored in Gowin pROM (gowin_bsram_hamming): depth=64, width=8, Q0.8
//   coeff[0] = coeff[63] = 0x14 (20), coeff[32] = 0xFF (255)
//
// Arithmetic: windowed[n] = (sample[n] * coeff[n]) >>> 8  (arithmetic right-shift)
// Latency: 64 + 1 cycles per frame (1 cycle ROM read latency)
module hamming_window (
    input  sys_clk,
    input  rst_n,

    // Input: one INT16 sample per cycle, 64 cycles per frame
    input  signed [15:0] sample_in,
    input                sample_valid,    // must pulse 64 times per frame
    input                frame_start,     // pulse on first sample of frame

    // Output: one INT16 windowed sample per cycle
    output reg signed [15:0] windowed_out,
    output reg               windowed_valid,

    // pROM interface, driven by the parent IP instance
    output [5:0]             rom_addr_out,
    input  [7:0]             rom_data
);

// ── pROM interface ────────────────────────────────────────────────────────────
// Instantiated externally (gowin_bsram_hamming IP).
// Here we drive the address and read the data.

reg  [5:0]  rom_addr;

// ── Pipeline ──────────────────────────────────────────────────────────────────

reg signed [15:0] sample_d1;    // delay sample 1 cycle to match ROM latency
reg               valid_d1;
reg [5:0]         cnt;

always @(posedge sys_clk or negedge rst_n) begin
    if (!rst_n) begin
        cnt          <= 6'd0;
        rom_addr     <= 6'd0;
        sample_d1    <= 16'd0;
        valid_d1     <= 1'b0;
        windowed_out <= 16'd0;
        windowed_valid <= 1'b0;
    end else begin
        windowed_valid <= 1'b0;

        // Stage 1: issue ROM read address = sample index
        if (frame_start)
            cnt <= 6'd0;

        if (sample_valid) begin
            rom_addr  <= cnt;
            sample_d1 <= sample_in;
            valid_d1  <= 1'b1;
            cnt       <= cnt + 1'b1;
        end else begin
            valid_d1  <= 1'b0;
        end

        // Stage 2: ROM data arrives 1 cycle later (registered ROM output)
        if (valid_d1) begin
            // (INT16 * UINT8) >> 8 = INT16
            // Use 24-bit intermediate to avoid overflow before shift
            windowed_out   <= $signed(sample_d1 * $signed({1'b0, rom_data})) >>> 8;
            windowed_valid <= 1'b1;
        end
    end
end

// Export ROM address for parent to connect to pROM IP
assign rom_addr_out = rom_addr;

// Note: rom_data must be wired from gowin_bsram_hamming.dout in parent module

endmodule
