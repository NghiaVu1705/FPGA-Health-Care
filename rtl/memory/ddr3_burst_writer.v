// ddr3_burst_writer.v - Packs an 8-bit stream into Gowin DDR3 256-bit writes.
//
// The Gowin DDR3MI native port exposes 256-bit write data. This block accepts
// a byte stream, emits one command/data beat per 32 bytes, and uses the mask on
// the final partial beat. CMD_WRITE defaults to 3'b000, matching the existing
// Gowin video-frame-buffer wrapper convention in this project.
module ddr3_burst_writer #(
    parameter CMD_WRITE = 3'b000
)(
    input              sys_clk,
    input              rst_n,

    input              start,
    input      [28:0]  base_addr,
    input      [31:0]  byte_count,
    output reg         busy,
    output reg         done,

    input      [7:0]   stream_data,
    input              stream_valid,
    output             stream_ready,

    input              ddr_cmd_ready,
    output reg [2:0]   ddr_cmd,
    output reg         ddr_cmd_en,
    output reg [28:0]  ddr_addr,

    input              ddr_wr_data_rdy,
    output reg [255:0] ddr_wr_data,
    output reg         ddr_wr_data_en,
    output reg         ddr_wr_data_end,
    output reg [31:0]  ddr_wr_data_mask
);

localparam [1:0]
    ST_IDLE  = 2'd0,
    ST_FILL  = 2'd1,
    ST_ISSUE = 2'd2,
    ST_DONE  = 2'd3;

reg [1:0] state;
reg [255:0] word_buf;
reg [5:0] fill_count;
reg [5:0] send_count;
reg [31:0] remaining;
reg [28:0] addr_reg;

wire take_byte = stream_valid && stream_ready;
wire issue_beat = ddr_cmd_ready && ddr_wr_data_rdy;

assign stream_ready = (state == ST_FILL);

function [31:0] mask_for_count;
    input [5:0] count;
    integer i;
    begin
        mask_for_count = 32'hffff_ffff;
        for (i = 0; i < 32; i = i + 1) begin
            if (i < count)
                mask_for_count[i] = 1'b0;
        end
    end
endfunction

always @(posedge sys_clk or negedge rst_n) begin
    if (!rst_n) begin
        state            <= ST_IDLE;
        busy             <= 1'b0;
        done             <= 1'b0;
        word_buf         <= 256'd0;
        fill_count       <= 6'd0;
        send_count       <= 6'd0;
        remaining        <= 32'd0;
        addr_reg         <= 29'd0;
        ddr_cmd          <= CMD_WRITE;
        ddr_cmd_en       <= 1'b0;
        ddr_addr         <= 29'd0;
        ddr_wr_data      <= 256'd0;
        ddr_wr_data_en   <= 1'b0;
        ddr_wr_data_end  <= 1'b0;
        ddr_wr_data_mask <= 32'hffff_ffff;
    end else begin
        done            <= 1'b0;
        ddr_cmd_en      <= 1'b0;
        ddr_wr_data_en  <= 1'b0;
        ddr_wr_data_end <= 1'b0;

        case (state)
            ST_IDLE: begin
                busy <= 1'b0;
                if (start) begin
                    busy       <= 1'b1;
                    addr_reg   <= base_addr;
                    remaining  <= byte_count;
                    word_buf   <= 256'd0;
                    fill_count <= 6'd0;
                    send_count <= 6'd0;
                    if (byte_count == 32'd0)
                        state <= ST_DONE;
                    else
                        state <= ST_FILL;
                end
            end

            ST_FILL: begin
                if (take_byte) begin
                    word_buf[(fill_count*8)+:8] <= stream_data;
                    fill_count <= fill_count + 1'b1;
                    remaining  <= remaining - 1'b1;

                    if ((fill_count == 6'd31) || (remaining == 32'd1)) begin
                        send_count <= fill_count + 1'b1;
                        state      <= ST_ISSUE;
                    end
                end
            end

            ST_ISSUE: begin
                if (issue_beat) begin
                    ddr_cmd          <= CMD_WRITE;
                    ddr_cmd_en       <= 1'b1;
                    ddr_addr         <= addr_reg;
                    ddr_wr_data      <= word_buf;
                    ddr_wr_data_en   <= 1'b1;
                    ddr_wr_data_end  <= 1'b1;
                    ddr_wr_data_mask <= mask_for_count(send_count);

                    addr_reg   <= addr_reg + 29'd32;
                    word_buf   <= 256'd0;
                    fill_count <= 6'd0;

                    if (remaining == 32'd0)
                        state <= ST_DONE;
                    else
                        state <= ST_FILL;
                end
            end

            ST_DONE: begin
                busy <= 1'b0;
                done <= 1'b1;
                state <= ST_IDLE;
            end

            default: begin
                state <= ST_IDLE;
                busy  <= 1'b0;
            end
        endcase
    end
end

endmodule
