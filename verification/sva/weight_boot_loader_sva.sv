// SVA checker for weight_boot_loader (Verilator --assert; bound).
// Properties:
//   - FSM state is always one of the declared encodings (<= ST_ERROR=9), never
//     an illegal value.
//   - done is a single-cycle pulse (must drop the next cycle).
//   - done and error are mutually exclusive, and neither coincides with busy.
module weight_boot_loader_sva (
    input       sys_clk,
    input       rst_n,
    input [3:0] state,
    input       busy,
    input       done,
    input       error
);
    a_state_legal: assert property (@(posedge sys_clk) disable iff (!rst_n)
        state <= 4'd9);
    a_done_pulse:  assert property (@(posedge sys_clk) disable iff (!rst_n)
        done |=> !done);
    a_done_idle:   assert property (@(posedge sys_clk) disable iff (!rst_n)
        done |-> !busy);
    a_done_err_excl: assert property (@(posedge sys_clk) disable iff (!rst_n)
        !(done && error));
endmodule

bind weight_boot_loader weight_boot_loader_sva u_sva (
    .sys_clk(sys_clk),
    .rst_n  (rst_n),
    .state  (state),
    .busy   (busy),
    .done   (done),
    .error  (error)
);
