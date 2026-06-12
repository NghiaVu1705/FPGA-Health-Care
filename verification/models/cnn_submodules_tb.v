`timescale 1ns/1ps

module cnn_submodules_tb (
    input sys_clk,
    input rst_n,

    input  signed [15:0] relu_x,
    output [15:0]        relu_y,

    input        dw_x_valid,
    input        dw_frame_start,
    input [15:0] dw_x_in,
    input [71:0] dw_w,
    input [31:0] dw_b,
    output [15:0] dw_y_out,
    output        dw_y_valid,

    input         pw_x_valid,
    input         pw_frame_start,
    input  [31:0] pw_x_in,
    input  [31:0] pw_w,
    input  [63:0] pw_b,
    output [31:0] pw_y_out,
    output        pw_y_valid,

    input        mp_x_valid,
    input        mp_frame_start,
    input [15:0] mp_x_in,
    output [15:0] mp_y_out,
    output        mp_y_valid,

    input        gap_x_valid,
    input        gap_frame_start,
    input [15:0] gap_x_in,
    output [15:0] gap_out,
    output        gap_valid,

    input        fc_gap_valid,
    input [31:0] fc_gap_in,
    input [47:0] fc_w,
    input [95:0] fc_b,
    output [23:0] fc_logits,
    output        fc_logits_valid,
    output [1:0]  fc_class_out
);

relu_unit u_relu (
    .x_in(relu_x),
    .y_out(relu_y)
);

conv2d_engine #(
    .MODE("DW"), .C_IN(1), .C_OUT(1), .C_OUT_EFF(1), .W_DEPTH(9),
    .H(2), .W(2), .SHIFT(0)
) u_dw (
    .sys_clk(sys_clk), .rst_n(rst_n),
    .x_in(dw_x_in), .x_valid(dw_x_valid), .frame_start(dw_frame_start),
    .w(dw_w), .b(dw_b),
    .y_out(dw_y_out), .y_valid(dw_y_valid)
);

conv2d_engine #(
    .MODE("PW"), .C_IN(2), .C_OUT(2), .C_OUT_EFF(2), .W_DEPTH(4),
    .H(2), .W(2), .SHIFT(0)
) u_pw (
    .sys_clk(sys_clk), .rst_n(rst_n),
    .x_in(pw_x_in), .x_valid(pw_x_valid), .frame_start(pw_frame_start),
    .w(pw_w), .b(pw_b),
    .y_out(pw_y_out), .y_valid(pw_y_valid)
);

maxpool_unit #(.C(1), .H(2), .W(2)) u_mp (
    .sys_clk(sys_clk), .rst_n(rst_n),
    .x_in(mp_x_in), .x_valid(mp_x_valid), .frame_start(mp_frame_start),
    .y_out(mp_y_out), .y_valid(mp_y_valid)
);

global_maxpool_unit #(.C(1), .H(2), .W(2)) u_gap (
    .sys_clk(sys_clk), .rst_n(rst_n),
    .x_in(gap_x_in), .x_valid(gap_x_valid), .frame_start(gap_frame_start),
    .gap_out(gap_out), .gap_valid(gap_valid)
);

fc_layer #(.C_IN(2), .C_OUT(3)) u_fc (
    .sys_clk(sys_clk), .rst_n(rst_n),
    .gap_in(fc_gap_in), .gap_valid(fc_gap_valid), .shift(5'd0),
    .w(fc_w), .b(fc_b),
    .logits(fc_logits), .logits_valid(fc_logits_valid), .class_out(fc_class_out)
);

endmodule
