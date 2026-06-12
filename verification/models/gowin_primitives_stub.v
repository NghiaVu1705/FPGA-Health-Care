// Minimal simulation stubs for Gowin primitives.
//
// These models are intentionally simple. They let open-source simulators compile
// and smoke-test top-level connectivity without requiring the Gowin vendor
// simulation libraries.
`timescale 1ns/1ps

module PLL (
    output LOCK,
    output CLKOUT0,
    output CLKOUT1,
    output CLKOUT2,
    output CLKOUT3,
    output CLKOUT4,
    output CLKOUT5,
    output CLKOUT6,
    output CLKFBOUT,
    input  CLKIN,
    input  CLKFB,
    input  RESET,
    input  PLLPWD,
    input  RESET_I,
    input  RESET_O,
    input  [5:0] FBDSEL,
    input  [5:0] IDSEL,
    input  [6:0] MDSEL,
    input  [2:0] MDSEL_FRAC,
    input  [6:0] ODSEL0,
    input  [2:0] ODSEL0_FRAC,
    input  [6:0] ODSEL1,
    input  [6:0] ODSEL2,
    input  [6:0] ODSEL3,
    input  [6:0] ODSEL4,
    input  [6:0] ODSEL5,
    input  [6:0] ODSEL6,
    input  [3:0] DT0,
    input  [3:0] DT1,
    input  [3:0] DT2,
    input  [3:0] DT3,
    input  [5:0] ICPSEL,
    input  [2:0] LPFRES,
    input  [1:0] LPFCAP,
    input  [2:0] PSSEL,
    input  PSDIR,
    input  PSPULSE,
    input  ENCLK0,
    input  ENCLK1,
    input  ENCLK2,
    input  ENCLK3,
    input  ENCLK4,
    input  ENCLK5,
    input  ENCLK6,
    input  SSCPOL,
    input  SSCON,
    input  [6:0] SSCMDSEL,
    input  [2:0] SSCMDSEL_FRAC
);

parameter FCLKIN = "27";
parameter IDIV_SEL = 1;
parameter FBDIV_SEL = 1;
parameter ODIV0_SEL = 8;
parameter ODIV1_SEL = 8;
parameter ODIV2_SEL = 8;
parameter ODIV3_SEL = 8;
parameter ODIV4_SEL = 8;
parameter ODIV5_SEL = 8;
parameter ODIV6_SEL = 8;
parameter MDIV_SEL = 1;
parameter MDIV_FRAC_SEL = 0;
parameter ODIV0_FRAC_SEL = 0;
parameter CLKOUT0_EN = "TRUE";
parameter CLKOUT1_EN = "FALSE";
parameter CLKOUT2_EN = "FALSE";
parameter CLKOUT3_EN = "FALSE";
parameter CLKOUT4_EN = "FALSE";
parameter CLKOUT5_EN = "FALSE";
parameter CLKOUT6_EN = "FALSE";
parameter CLKFB_SEL = "INTERNAL";
parameter CLKOUT0_DT_DIR = 1'b1;
parameter CLKOUT1_DT_DIR = 1'b1;
parameter CLKOUT2_DT_DIR = 1'b1;
parameter CLKOUT3_DT_DIR = 1'b1;
parameter CLKOUT0_DT_STEP = 0;
parameter CLKOUT1_DT_STEP = 0;
parameter CLKOUT2_DT_STEP = 0;
parameter CLKOUT3_DT_STEP = 0;
parameter CLK0_IN_SEL = 1'b0;
parameter CLK1_IN_SEL = 1'b0;
parameter CLK2_IN_SEL = 1'b0;
parameter CLK3_IN_SEL = 1'b0;
parameter CLK4_IN_SEL = 1'b0;
parameter CLK5_IN_SEL = 1'b0;
parameter CLK6_IN_SEL = 1'b0;
parameter CLK0_OUT_SEL = 1'b0;
parameter CLK1_OUT_SEL = 1'b0;
parameter CLK2_OUT_SEL = 1'b0;
parameter CLK3_OUT_SEL = 1'b0;
parameter CLK4_OUT_SEL = 1'b0;
parameter CLK5_OUT_SEL = 1'b0;
parameter CLK6_OUT_SEL = 1'b0;
parameter CLKOUT0_PE_COARSE = 0;
parameter CLKOUT1_PE_COARSE = 0;
parameter CLKOUT2_PE_COARSE = 0;
parameter CLKOUT3_PE_COARSE = 0;
parameter CLKOUT4_PE_COARSE = 0;
parameter CLKOUT5_PE_COARSE = 0;
parameter CLKOUT6_PE_COARSE = 0;
parameter CLKOUT0_PE_FINE = 0;
parameter CLKOUT1_PE_FINE = 0;
parameter CLKOUT2_PE_FINE = 0;
parameter CLKOUT3_PE_FINE = 0;
parameter CLKOUT4_PE_FINE = 0;
parameter CLKOUT5_PE_FINE = 0;
parameter CLKOUT6_PE_FINE = 0;
parameter DYN_DPA_EN = "FALSE";
parameter DE0_EN = "FALSE";
parameter DE1_EN = "FALSE";
parameter DE2_EN = "FALSE";
parameter DE3_EN = "FALSE";
parameter DE4_EN = "FALSE";
parameter DE5_EN = "FALSE";
parameter DE6_EN = "FALSE";
parameter RESET_I_EN = "FALSE";
parameter RESET_O_EN = "FALSE";
parameter ICP_SEL = 6'b000000;
parameter LPF_RES = 3'b000;
parameter LPF_CAP = 2'b00;
parameter SSC_EN = "FALSE";
parameter DYN_IDIV_SEL = "FALSE";
parameter DYN_FBDIV_SEL = "FALSE";
parameter DYN_MDIV_SEL = "FALSE";
parameter DYN_ODIV0_SEL = "FALSE";
parameter DYN_ODIV1_SEL = "FALSE";
parameter DYN_ODIV2_SEL = "FALSE";
parameter DYN_ODIV3_SEL = "FALSE";
parameter DYN_ODIV4_SEL = "FALSE";
parameter DYN_ODIV5_SEL = "FALSE";
parameter DYN_ODIV6_SEL = "FALSE";
parameter DYN_DT0_SEL = "FALSE";
parameter DYN_DT1_SEL = "FALSE";
parameter DYN_DT2_SEL = "FALSE";
parameter DYN_DT3_SEL = "FALSE";
parameter DYN_ICP_SEL = "FALSE";
parameter DYN_LPF_SEL = "FALSE";
parameter DYN_PE0_SEL = "FALSE";
parameter DYN_PE1_SEL = "FALSE";
parameter DYN_PE2_SEL = "FALSE";
parameter DYN_PE3_SEL = "FALSE";
parameter DYN_PE4_SEL = "FALSE";
parameter DYN_PE5_SEL = "FALSE";
parameter DYN_PE6_SEL = "FALSE";

assign LOCK = !(RESET || PLLPWD || RESET_I || RESET_O);
assign CLKOUT0 = ENCLK0 ? CLKIN : 1'b0;
assign CLKOUT1 = ENCLK1 ? CLKIN : 1'b0;
assign CLKOUT2 = ENCLK2 ? CLKIN : 1'b0;
assign CLKOUT3 = ENCLK3 ? CLKIN : 1'b0;
assign CLKOUT4 = ENCLK4 ? CLKIN : 1'b0;
assign CLKOUT5 = ENCLK5 ? CLKIN : 1'b0;
assign CLKOUT6 = ENCLK6 ? CLKIN : 1'b0;
assign CLKFBOUT = CLKIN;

endmodule

module SP (
    output reg [31:0] DO,
    input      [31:0] DI,
    input      [2:0]  BLKSEL,
    input      [13:0] AD,
    input             WRE,
    input             CLK,
    input             CE,
    input             OCE,
    input             RESET
);

parameter BIT_WIDTH = 32;
parameter RESET_MODE = "SYNC";
parameter INIT_RAM_00 = 256'h0;
parameter INIT_RAM_01 = 256'h0;
parameter INIT_RAM_02 = 256'h0;
parameter INIT_RAM_03 = 256'h0;
parameter INIT_RAM_04 = 256'h0;
parameter INIT_RAM_05 = 256'h0;
parameter INIT_RAM_06 = 256'h0;
parameter INIT_RAM_07 = 256'h0;
parameter INIT_RAM_08 = 256'h0;
parameter INIT_RAM_09 = 256'h0;
parameter INIT_RAM_0A = 256'h0;
parameter INIT_RAM_0B = 256'h0;
parameter INIT_RAM_0C = 256'h0;
parameter INIT_RAM_0D = 256'h0;
parameter INIT_RAM_0E = 256'h0;
parameter INIT_RAM_0F = 256'h0;
parameter INIT_RAM_10 = 256'h0;
parameter INIT_RAM_11 = 256'h0;
parameter INIT_RAM_12 = 256'h0;
parameter INIT_RAM_13 = 256'h0;
parameter INIT_RAM_14 = 256'h0;
parameter INIT_RAM_15 = 256'h0;
parameter INIT_RAM_16 = 256'h0;
parameter INIT_RAM_17 = 256'h0;
parameter INIT_RAM_18 = 256'h0;
parameter INIT_RAM_19 = 256'h0;
parameter INIT_RAM_1A = 256'h0;
parameter INIT_RAM_1B = 256'h0;
parameter INIT_RAM_1C = 256'h0;
parameter INIT_RAM_1D = 256'h0;
parameter INIT_RAM_1E = 256'h0;
parameter INIT_RAM_1F = 256'h0;
parameter INIT_RAM_20 = 256'h0;
parameter INIT_RAM_21 = 256'h0;
parameter INIT_RAM_22 = 256'h0;
parameter INIT_RAM_23 = 256'h0;
parameter INIT_RAM_24 = 256'h0;
parameter INIT_RAM_25 = 256'h0;
parameter INIT_RAM_26 = 256'h0;
parameter INIT_RAM_27 = 256'h0;
parameter INIT_RAM_28 = 256'h0;
parameter INIT_RAM_29 = 256'h0;
parameter INIT_RAM_2A = 256'h0;
parameter INIT_RAM_2B = 256'h0;
parameter INIT_RAM_2C = 256'h0;
parameter INIT_RAM_2D = 256'h0;
parameter INIT_RAM_2E = 256'h0;
parameter INIT_RAM_2F = 256'h0;
parameter INIT_RAM_30 = 256'h0;
parameter INIT_RAM_31 = 256'h0;
parameter INIT_RAM_32 = 256'h0;
parameter INIT_RAM_33 = 256'h0;
parameter INIT_RAM_34 = 256'h0;
parameter INIT_RAM_35 = 256'h0;
parameter INIT_RAM_36 = 256'h0;
parameter INIT_RAM_37 = 256'h0;
parameter INIT_RAM_38 = 256'h0;
parameter INIT_RAM_39 = 256'h0;
parameter INIT_RAM_3A = 256'h0;
parameter INIT_RAM_3B = 256'h0;
parameter INIT_RAM_3C = 256'h0;
parameter INIT_RAM_3D = 256'h0;
parameter INIT_RAM_3E = 256'h0;
parameter INIT_RAM_3F = 256'h0;

reg [31:0] mem [0:16383];
integer i;

initial begin
    for (i = 0; i < 16384; i = i + 1)
        mem[i] = 32'd0;
    DO = 32'd0;
end

always @(posedge CLK) begin
    if (RESET) begin
        DO <= 32'd0;
    end else if (CE) begin
        if (WRE)
            mem[AD] <= DI;
        if (OCE)
            DO <= mem[AD];
    end
end

endmodule

module OSER10 (
    output Q,
    input D0,
    input D1,
    input D2,
    input D3,
    input D4,
    input D5,
    input D6,
    input D7,
    input D8,
    input D9,
    input PCLK,
    input FCLK,
    input RESET
);

assign Q = RESET ? 1'b0 : D0;

endmodule

module ELVDS_OBUF (
    input  I,
    output O,
    output OB
);

assign O = I;
assign OB = ~I;

endmodule
