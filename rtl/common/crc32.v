`default_nettype none
// crc32.v - CRC32 dạng luồng theo byte (IEEE 802.3, đảo bit - reflected).
//
// Khớp với binascii.crc32 và zlib.crc32 của Python:
//   đa thức 0xEDB88320 (bản đảo bit của 0x04C11DB7)
//   giá trị khởi tạo 0xFFFFFFFF
//   XOR cuối cùng với 0xFFFFFFFF
//
// Cách dùng:
//   - bật `clear` một chu kỳ để reset bộ tích lũy CRC trước một luồng mới
//   - bật `data_valid` cùng với byte trên `data` cho mỗi byte cần đưa vào
//   - `crc` là giá trị sau XOR (tức giá trị để so sánh với kỳ vọng) và hợp lệ
//     theo tổ hợp (combinational); hãy lấy mẫu nó ở chu kỳ NGAY SAU khi byte
//     cuối cùng được tiêu thụ.
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
