`timescale 1ns/1ps

module vendor_boundary_tb (
    input         clk,
    input         rst_n,
    input  [5:0]  hamming_addr,
    output [7:0]  hamming_data,
    input  [4:0]  twiddle_addr,
    output [31:0] twiddle_data,
    input         fifo_wr_en,
    input         fifo_rd_en,
    input  [15:0] fifo_data,
    output [15:0] fifo_q,
    output        fifo_empty,
    output        fifo_full,
    output        pll_lock,
    output        pll_clk0,
    output        pll_clk1,
    input         rgb_vs,
    input         rgb_hs,
    input         rgb_de,
    input  [7:0]  rgb_r,
    input  [7:0]  rgb_g,
    input  [7:0]  rgb_b,
    output        tmds_clk_p,
    output        tmds_clk_n,
    output [2:0]  tmds_data_p,
    output [2:0]  tmds_data_n
);

gowin_bsram_hamming u_hamming (
    .clk(clk),
    .addr(hamming_addr),
    .dout(hamming_data)
);

gowin_bsram_twiddle u_twiddle (
    .clk(clk),
    .addr(twiddle_addr),
    .dout(twiddle_data)
);

gowin_fifo_async u_fifo (
    .Reset(~rst_n),
    .WrClk(clk),
    .RdClk(clk),
    .WrEn(fifo_wr_en),
    .RdEn(fifo_rd_en),
    .Data(fifo_data),
    .Q(fifo_q),
    .Empty(fifo_empty),
    .Full(fifo_full)
);

TMDS_PLL u_pll (
    .clkin(clk),
    .init_clk(clk),
    .clkout0(pll_clk0),
    .clkout1(pll_clk1),
    .lock(pll_lock)
);

DVI_TX_Top u_dvi (
    .I_rst_n(rst_n),
    .I_serial_clk(clk),
    .I_rgb_clk(clk),
    .I_rgb_vs(rgb_vs),
    .I_rgb_hs(rgb_hs),
    .I_rgb_de(rgb_de),
    .I_rgb_r(rgb_r),
    .I_rgb_g(rgb_g),
    .I_rgb_b(rgb_b),
    .O_tmds_clk_p(tmds_clk_p),
    .O_tmds_clk_n(tmds_clk_n),
    .O_tmds_data_p(tmds_data_p),
    .O_tmds_data_n(tmds_data_n)
);

endmodule
