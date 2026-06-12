`default_nettype none
// sram_sp.v - generic single-port synchronous SRAM wrapper.
//
// Technology-neutral interface used by both FPGA and ASIC flows:
//   - On FPGA: synthesizes to BSRAM/LUTRAM via inference; `syn_ramstyle`
//     attribute exposed via parameter `RAM_STYLE`.
//   - On ASIC: swap with a memory-compiler macro behind this same interface.
//
// Single port: one read OR one write per cycle. Read latency = 1 cycle
// (rdata stable on the cycle AFTER the address is presented).
//
// No asynchronous reset on the memory array (BSRAM cells have no reset);
// rdata register is also not reset for portability across vendor BSRAMs.
module sram_sp #(
    parameter DEPTH     = 512,
    parameter DATA_W    = 8,
    parameter ADDR_W    = 9,
    parameter RAM_STYLE = "block_ram"
)(
    input  wire                  clk,
    input  wire                  ce,
    input  wire                  we,
    input  wire [ADDR_W-1:0]     addr,
    input  wire [DATA_W-1:0]     wdata,
    output reg  [DATA_W-1:0]     rdata
);

(* syn_ramstyle = RAM_STYLE *) reg [DATA_W-1:0] mem [0:DEPTH-1];

always @(posedge clk) begin
    if (ce) begin
        if (we) mem[addr] <= wdata;
        else    rdata     <= mem[addr];
    end
end

endmodule

`default_nettype wire
