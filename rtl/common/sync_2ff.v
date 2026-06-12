`default_nettype none
// sync_2ff.v - two-flip-flop single-bit synchronizer (CDC).
//
// Use this for individual asynchronous bits whose value is stable for many
// destination-clock periods. Do NOT use bit-wise instances on a multi-bit
// bus that must update atomically — use `cdc_bus_handshake.v` for that
// case.
//
// Implementation notes:
//   - `dst_clk` registers receive the asynchronous input through STAGES FFs.
//     STAGES=2 is the textbook minimum; STAGES=3 is more conservative for
//     fast pixel_clk / sys_clk domains on Gowin.
//   - Synthesis attributes (Gowin-specific) tag the chain so optimisation
//     does not merge or move the FFs:
//       syn_keep, syn_preserve, syn_srlstyle="registers".
//   - The reset is async-assert / sync-release on `dst_clk`, matching the
//     project's overall reset convention.
//
// MTBF: with 2 stages, sub-femtosecond unreliability for tau<<period at
// modern speeds. See standard CDC literature.
module sync_2ff #(
    parameter STAGES = 2,
    parameter INIT_VALUE = 1'b0
)(
    input  wire dst_clk,
    input  wire dst_rst_n,
    input  wire async_in,
    output wire sync_out
);

(* syn_keep = 1, syn_preserve = 1, syn_srlstyle = "registers" *)
reg [STAGES-1:0] sync_chain;

assign sync_out = sync_chain[STAGES-1];

always @(posedge dst_clk or negedge dst_rst_n) begin
    if (!dst_rst_n)
        sync_chain <= {STAGES{INIT_VALUE}};
    else
        sync_chain <= {sync_chain[STAGES-2:0], async_in};
end

endmodule

`default_nettype wire
