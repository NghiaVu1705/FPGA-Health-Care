// Simulation stub for TMDS_PLL
module TMDS_PLL (
    input  clkin,
    input  init_clk,
    output clkout0,
    output clkout1,
    output lock
);
    assign clkout0 = clkin;
    assign clkout1 = clkin;
    assign lock    = 1'b1;
endmodule
