`default_nettype none
// sram_sp.v - lớp bọc (wrapper) SRAM đồng bộ đơn cổng tổng quát.
//
// Giao diện trung lập về công nghệ, dùng cho cả luồng FPGA và ASIC:
//   - Trên FPGA: được tổng hợp thành BSRAM/LUTRAM qua suy luận (inference); thuộc
//     tính `syn_ramstyle` được lộ ra qua tham số `RAM_STYLE`.
//   - Trên ASIC: thay bằng macro của trình biên dịch bộ nhớ (memory-compiler) sau
//     cùng giao diện này.
//
// Đơn cổng: một thao tác đọc HOẶC một thao tác ghi mỗi chu kỳ. Độ trễ đọc = 1 chu
// kỳ (rdata ổn định ở chu kỳ NGAY SAU khi địa chỉ được đưa vào).
//
// Không có reset bất đồng bộ trên mảng bộ nhớ (ô BSRAM không có reset);
// thanh ghi rdata cũng không được reset để dễ chuyển đổi giữa các BSRAM của các nhà
// cung cấp khác nhau.
module sram_sp #(
    parameter DEPTH     = 512,
    parameter DATA_W    = 8,
    parameter ADDR_W    = 9,
    parameter RAM_STYLE = "block_ram"
)(
    input  wire                  clk,
    input  wire                  ce,
    input  wire                  we,
    input  wire [ADDR_W-1:0]     addr,
    input  wire [DATA_W-1:0]     wdata,
    output reg  [DATA_W-1:0]     rdata
);

(* syn_ramstyle = RAM_STYLE *) reg [DATA_W-1:0] mem [0:DEPTH-1];

always @(posedge clk) begin
    if (ce) begin
        if (we) mem[addr] <= wdata;
        else    rdata     <= mem[addr];
    end
end

endmodule

`default_nettype wire
