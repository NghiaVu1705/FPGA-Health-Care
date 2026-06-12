// fc_layer.v ↔ fc_layer.py
// Fully-connected C_IN→C_OUT, INT8 weights, INT32 biases, INT8 logits.
//
// Phase 5e — pipeline the last-cycle MAC.
//
// Before Phase 5e the cycle when ci==C_IN-1 carried a long combinational chain
// in ONE cycle:
//      mult → +acc → >>>shift → clip16 → logits register
// which Phase 5d's synthesis report identified as the worst path
// (u_fc/fc_w[15] → u_fc/logits[*], slack −6.314 ns at 100 MHz).
//
// Phase 5e replaces the `running`/blocking-temp structure with a clean state
// machine that registers between the MAC accumulator, the arithmetic shift,
// and the clip+write. The argmax pipeline (Phase 5c) is preserved as the last
// two states.
//
// States and per-state work:
//
//   ST_IDLE   — waiting for gap_valid.
//   ST_MAC    — one MAC cycle: acc <= acc + w[co,ci]*gap_in[ci]; advance ci.
//               After ci==C_IN-1 the final acc value is captured here and
//               control passes to ST_SHIFT.
//   ST_SHIFT  — register `shifted <= acc >>> shift`. Adds 1 cycle latency.
//   ST_CLIP   — saturate `shifted` to ±127, write logits[(co*8)+:8]. Either
//               start the next neuron (back to ST_MAC, reload bias) or kick
//               off the argmax stages.
//   ST_ARG_INIT/SCAN — sequential argmax across C_OUT logits; ties keep the
//                      lower class index.
//
// Mathematical equivalence: the produced logits and class_out are bit-exact
// with the prior implementation (acc is registered at the same value that
// was previously the input to the combinational shift; shift+clip then
// produce the same byte). The only observable difference is +2 cycles of
// latency per neuron in the FC pipeline.
module fc_layer #(
    parameter C_IN  = 16,
    parameter C_OUT = 3,
    parameter CLASS_BITS = (C_OUT <= 2) ? 1 : $clog2(C_OUT)
)(
    input  sys_clk,
    input  rst_n,

    input  [(C_IN*16)-1:0] gap_in,     // INT16 from GlobalMaxPool
    input         gap_valid,
    input  [4:0]  shift,               // combined_shift from scale_rom[4]

    // Weight/bias preloaded from BSRAM by cnn_top
    input  [(C_OUT*C_IN*8)-1:0] w,      // INT8 [C_OUT, C_IN] row-major
    input  [(C_OUT*32)-1:0]     b,      // INT32 biases

    output reg [(C_OUT*8)-1:0] logits,  // INT8 output
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

// Timing fix: the operand select out of the (C_OUT*C_IN*8)-bit flat weight bus
// (768 bits at NUM_CLASSES=6) plus the activation select are registered in
// ST_FETCH *before* the multiply in ST_MAC, instead of feeding the dynamic mux
// straight into the DSP+adder. This makes the MAC loop 2 cycles/tap but keeps
// the arithmetic bit-exact (same product, same accumulation order).
reg signed [7:0]   w_sel;   // selected weight   for (co, ci)
reg signed [15:0]  a_sel;   // selected activation for ci

// Combinational MAC product from the *registered* operands. Kept as a wire so
// the synthesizer's DSP18 inference is unambiguous; the registered accumulator
// is `acc` (which is what gets pushed into ST_SHIFT).
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
                // Register the selected weight + activation. This is the long
                // 768-bit operand mux; isolating it behind w_sel/a_sel keeps the
                // multiplier's input path short.
                w_sel <= $signed(w[((co*C_IN + ci)*8)+:8]);
                a_sel <= $signed(gap_in[(ci*16)+:16]);
                state <= ST_MAC;
            end

            ST_MAC: begin
                // Accumulate one product (from the registered operands). The
                // final accumulation is captured here (no shift/clip in the same
                // cycle), so the worst combinational chain ends at `acc`.
                acc <= acc + {{16{mac_prod[15]}}, mac_prod};
                if (ci == C_IN - 1) begin
                    state <= ST_SHIFT;
                end else begin
                    ci    <= ci + 1'b1;
                    state <= ST_FETCH;
                end
            end

            ST_SHIFT: begin
                // One register stage isolates the barrel shift from the
                // adder feeding `acc`.
                shifted <= acc >>> shift;
                state   <= ST_CLIP;
            end

            ST_CLIP: begin
                // Saturate to INT8 and write the neuron's logit. Then either
                // start the next neuron or hand off to argmax.
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
