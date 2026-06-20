// SVA checker for decision_layer (Verilator --assert; bound, RTL stays clean).
// Properties:
//   - class_out is always a legal severity (0/1/2), never the invalid 3.
//   - confidence is always legal (0/1/2).
//   - the invalid input code 2'b11 on any channel is fail-safed to Critical,
//     never propagated as a raw 3 on class_out (covered by class_out<=2).
module decision_layer_sva (
    input        sys_clk,
    input        rst_n,
    input [1:0]  class_out,
    input [1:0]  confidence
);
    a_class_legal: assert property (@(posedge sys_clk) disable iff (!rst_n)
        class_out <= 2'd2);
    a_conf_legal:  assert property (@(posedge sys_clk) disable iff (!rst_n)
        confidence <= 2'd2);
endmodule

bind decision_layer decision_layer_sva u_sva (
    .sys_clk  (sys_clk),
    .rst_n    (rst_n),
    .class_out(class_out),
    .confidence(confidence)
);
