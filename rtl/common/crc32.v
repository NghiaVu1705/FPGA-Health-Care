`default_nettype none
// crc32.v - byte-streaming CRC32 (IEEE 802.3, reflected).
//
// Matches Python's binascii.crc32 and zlib.crc32:
//   polynomial 0xEDB88320 (reflected of 0x04C11DB7)
//   initial value 0xFFFFFFFF
//   final XOR with 0xFFFFFFFF
//
// Usage:
//   - assert `clear` for one cycle to reset CRC accumulator before a new stream
//   - assert `data_valid` with byte on `data` for each byte to include
//   - `crc` is the post-XOR (i.e. value to compare against expected) and is
//     valid combinationally; sample it the cycle AFTER the last byte was
//     consumed.
module crc32 (
    input  wire        sys_clk,
    input  wire        rst_n,
    input  wire        clear,
    input  wire        data_valid,
    input  wire [7:0]  data,
    output wire [31:0] crc
);

reg [31:0] crc_r;

assign crc = crc_r ^ 32'hFFFFFFFF;

function [31:0] crc32_step;
    input [31:0] crc_in;
    input [7:0]  byte_in;
    integer      bi;
    reg   [31:0] tmp;
    begin
        tmp = crc_in ^ {24'd0, byte_in};
        for (bi = 0; bi < 8; bi = bi + 1) begin
            if (tmp[0]) tmp = (tmp >> 1) ^ 32'hEDB88320;
            else        tmp = tmp >> 1;
        end
        crc32_step = tmp;
    end
endfunction

always @(posedge sys_clk or negedge rst_n) begin
    if (!rst_n)         crc_r <= 32'hFFFFFFFF;
    else if (clear)     crc_r <= 32'hFFFFFFFF;
    else if (data_valid) crc_r <= crc32_step(crc_r, data);
end

endmodule

`default_nettype wire
