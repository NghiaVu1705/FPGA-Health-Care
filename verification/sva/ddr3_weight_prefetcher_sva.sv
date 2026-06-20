// SVA checker for ddr3_weight_prefetcher (Verilator --assert; bound).
// Properties:
//   - FSM state is always legal (<= ST_ERROR=5).
//   - done and error never assert together.
//   - busy drops once done or error is reached.
//   - a cache write address always stays inside the 512-byte tile.
module ddr3_weight_prefetcher_sva (
    input       sys_clk,
    input       rst_n,
    input [2:0] state,
    input       busy,
    input       done,
    input       error,
    input       cache_wr_en,
    input [8:0] cache_wr_addr
);
    a_state_legal: assert property (@(posedge sys_clk) disable iff (!rst_n)
        state <= 3'd5);
    a_done_err_excl: assert property (@(posedge sys_clk) disable iff (!rst_n)
        !(done && error));
    a_cache_addr_range: assert property (@(posedge sys_clk) disable iff (!rst_n)
        cache_wr_en |-> cache_wr_addr <= 9'd511);
endmodule

bind ddr3_weight_prefetcher ddr3_weight_prefetcher_sva u_sva (
    .sys_clk      (sys_clk),
    .rst_n        (rst_n),
    .state        (state),
    .busy         (busy),
    .done         (done),
    .error        (error),
    .cache_wr_en  (cache_wr_en),
    .cache_wr_addr(cache_wr_addr)
);
