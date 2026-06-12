// Open-source simulator models for project-specific Gowin IP wrappers.
`timescale 1ns/1ps

`ifdef USE_GOWIN_IP_STUBS

module gowin_pll_sys (
    output lock,
    output clkout0,
    input  clkin
);
assign lock = 1'b1;
assign clkout0 = clkin;
endmodule

module gowin_pll_hdmi (
    output lock,
    output clkout0,
    output clkout1,
    input  clkin
);
assign lock = 1'b1;
assign clkout0 = clkin;
assign clkout1 = clkin;
endmodule

module gowin_bsram_hamming (
    input        clk,
    input  [5:0] addr,
    output reg [7:0] dout
);
reg [7:0] mem [0:63];
initial $readmemh("../rtl/gowin_bsram/hamming_coeff_rom.hex", mem);
always @(posedge clk) dout <= mem[addr];
endmodule

module gowin_bsram_twiddle (
    input         clk,
    input  [4:0] addr,
    output reg [31:0] dout
);
reg [31:0] mem [0:31];
initial $readmemh("../rtl/gowin_bsram/fft_twiddle_rom.hex", mem);
always @(posedge clk) dout <= mem[addr];
endmodule

module gowin_bsram_cnn_eeg (
    input        clk,
    input  [8:0] addr,
    output reg [7:0] dout
);
reg [7:0] mem [0:511];
initial $readmemh("../rtl/gowin_bsram/eeg/cnn_weights.hex", mem);
always @(posedge clk) dout <= mem[addr];
endmodule

module gowin_bsram_cnn_ecg (
    input        clk,
    input  [8:0] addr,
    output reg [7:0] dout
);
reg [7:0] mem [0:511];
initial $readmemh("../rtl/gowin_bsram/ecg/cnn_weights.hex", mem);
always @(posedge clk) dout <= mem[addr];
endmodule

module gowin_bsram_cnn_emg (
    input        clk,
    input  [8:0] addr,
    output reg [7:0] dout
);
reg [7:0] mem [0:511];
initial $readmemh("../rtl/gowin_bsram/emg/cnn_weights.hex", mem);
always @(posedge clk) dout <= mem[addr];
endmodule

module Gowin_PLL (
    input  clkin,
    input  init_clk,
    input  reset,
    input  enclk0,
    input  enclk1,
    input  enclk2,
    output clkout0,
    output clkout1,
    output clkout2,
    output lock
);
assign clkout0 = clkin;
assign clkout1 = clkin;
assign clkout2 = clkin;
assign lock    = ~reset;
endmodule

module DDR3MI (
    input          clk,
    output         pll_stop,
    input          memory_clk,
    input          pll_lock,
    input          rst_n,
    output         clk_out,
    output         ddr_rst,
    output         init_calib_complete,
    output         cmd_ready,
    input  [2:0]   cmd,
    input          cmd_en,
    input  [28:0]  addr,
    output         wr_data_rdy,
    input  [255:0] wr_data,
    input          wr_data_en,
    input          wr_data_end,
    input  [31:0]  wr_data_mask,
    output reg [255:0] rd_data,
    output reg     rd_data_valid,
    output         rd_data_end,
    input          sr_req,
    input          ref_req,
    output         sr_ack,
    output         ref_ack,
    input          burst,
    output [14:0]  O_ddr_addr,
    output [2:0]   O_ddr_ba,
    output         O_ddr_cs_n,
    output         O_ddr_ras_n,
    output         O_ddr_cas_n,
    output         O_ddr_we_n,
    output         O_ddr_clk,
    output         O_ddr_clk_n,
    output         O_ddr_cke,
    output         O_ddr_odt,
    output         O_ddr_reset_n,
    output [3:0]   O_ddr_dqm,
    inout  [31:0]  IO_ddr_dq,
    inout  [3:0]   IO_ddr_dqs,
    inout  [3:0]   IO_ddr_dqs_n
);
localparam [2:0] CMD_WRITE = 3'b000;
localparam [2:0] CMD_READ  = 3'b001;
localparam integer MEM_BYTES = 131072;

reg [7:0] mem [0:MEM_BYTES-1];
integer init_i;
integer byte_i;

initial begin
    for (init_i = 0; init_i < MEM_BYTES; init_i = init_i + 1)
        mem[init_i] = 8'd0;
end

assign pll_stop = 1'b0;
assign clk_out = clk;
assign ddr_rst = ~rst_n;
assign init_calib_complete = rst_n && pll_lock;
assign cmd_ready = init_calib_complete;
assign wr_data_rdy = init_calib_complete;
assign rd_data_end = rd_data_valid;
assign sr_ack = 1'b0;
assign ref_ack = 1'b0;
assign O_ddr_addr = 15'd0;
assign O_ddr_ba = 3'd0;
assign O_ddr_cs_n = 1'b1;
assign O_ddr_ras_n = 1'b1;
assign O_ddr_cas_n = 1'b1;
assign O_ddr_we_n = 1'b1;
assign O_ddr_clk = clk;
assign O_ddr_clk_n = ~clk;
assign O_ddr_cke = 1'b0;
assign O_ddr_odt = 1'b0;
assign O_ddr_reset_n = rst_n;
assign O_ddr_dqm = 4'hf;
assign IO_ddr_dq = 32'hzzzz_zzzz;
assign IO_ddr_dqs = 4'hz;
assign IO_ddr_dqs_n = 4'hz;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        rd_data <= 256'd0;
        rd_data_valid <= 1'b0;
    end else begin
        rd_data_valid <= 1'b0;

        if (cmd_en && cmd == CMD_WRITE && wr_data_en) begin
            for (byte_i = 0; byte_i < 32; byte_i = byte_i + 1) begin
                if (!wr_data_mask[byte_i] && ((addr + byte_i) < MEM_BYTES))
                    mem[addr + byte_i] <= wr_data[(byte_i * 8) +: 8];
            end
        end

        if (cmd_en && cmd == CMD_READ) begin
            for (byte_i = 0; byte_i < 32; byte_i = byte_i + 1) begin
                if ((addr + byte_i) < MEM_BYTES)
                    rd_data[(byte_i * 8) +: 8] <= mem[addr + byte_i];
                else
                    rd_data[(byte_i * 8) +: 8] <= 8'd0;
            end
            rd_data_valid <= 1'b1;
        end
    end
end
endmodule

`endif
