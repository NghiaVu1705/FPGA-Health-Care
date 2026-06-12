`timescale 1ns/1ps

module i2c_slave_tb #(
    parameter I2C_ADDR = 7'h48
)(
    input        sys_clk,
    input        rst_n,
    input        scl,
    input        sda_drive_en,
    input        sda_drive,
    output       sda_line,
    output [7:0] spo2_raw,
    output [7:0] temp_raw,
    output       data_updated
);

tri1 sda_bus;

assign sda_bus = sda_drive_en ? sda_drive : 1'bz;
assign sda_line = sda_bus;

i2c_slave #(.I2C_ADDR(I2C_ADDR)) u_dut (
    .sys_clk(sys_clk),
    .rst_n(rst_n),
    .scl(scl),
    .sda(sda_bus),
    .spo2_raw(spo2_raw),
    .temp_raw(temp_raw),
    .data_updated(data_updated)
);

endmodule
