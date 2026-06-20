// SVA checker for biomed_shared_ai_system (Verilator --assert; bound).
// DUT filename is shared_ai_system (toplevel = biomed_shared_ai_system).
// Properties:
//   - the scheduler FSM state is always legal (ST_PREFETCH..ST_NEXT = 0..5).
//   - the active channel is always one of EEG/ECG/EMG (0..2), never 3.
//   - weights_ready never asserts while a prefetch is still busy.
module shared_ai_system_sva (
    input       sys_clk,
    input       rst_n,
    input [2:0] state,
    input [1:0] channel,
    input       weights_ready,
    input       prefetch_busy
);
    a_state_legal: assert property (@(posedge sys_clk) disable iff (!rst_n)
        state <= 3'd5);
    a_chan_legal:  assert property (@(posedge sys_clk) disable iff (!rst_n)
        channel <= 2'd2);
    a_ready_not_busy: assert property (@(posedge sys_clk) disable iff (!rst_n)
        weights_ready |-> !prefetch_busy);
endmodule

bind biomed_shared_ai_system shared_ai_system_sva u_sva (
    .sys_clk      (sys_clk),
    .rst_n        (rst_n),
    .state        (state),
    .channel      (channel),
    .weights_ready(weights_ready),
    .prefetch_busy(prefetch_busy)
);
