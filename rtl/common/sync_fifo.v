// sync_fifo.v — FIFO đồng bộ (một clock), độ sâu tham số hóa được.
//
// Cả phía ghi và phía đọc đều chạy trên MỘT clock (`clk`): đây là FIFO đồng bộ
// thuần túy. Con trỏ đọc/ghi nhị phân được so sánh trực tiếp để suy ra
// Empty/Full, điều này CHỈ đúng vì chỉ có một miền clock duy nhất — KHÔNG có mã
// hóa Gray và KHÔNG có đồng bộ 2-FF. KHÔNG tái sử dụng module này qua hai clock
// bất đồng bộ; một FIFO CDC thực thụ cần con trỏ mã hóa Gray + các bộ đồng bộ
// (xem sync_2ff / cdc_bus_handshake để biết các khối CDC nguyên thủy dùng ở nơi
// khác).
//
// syn_ramstyle = "block_ram" ép suy luận thành BSRAM.
//
// Tham số:
//   DEPTH : số phần tử (lũy thừa của hai). Mặc định 256.
//   AW    : độ rộng địa chỉ, phải thỏa mãn DEPTH == (1<<AW). Mặc định 8.
// Con trỏ rộng AW+1 bit: bit MSB dư ra là bit vòng (wrap) dùng để phân biệt FIFO
// đầy với FIFO rỗng (sơ đồ kinh điển dùng một bit dư).
module sync_fifo #(
    parameter DEPTH = 256,
    parameter AW    = 8
)(
    input             Reset,
    input             clk,
    input             WrEn,
    input             RdEn,
    input  [15:0]     Data,
    output reg [15:0] Q,
    output            Empty,
    output            Full
);

(* syn_ramstyle = "block_ram" *) reg [15:0] mem [0:DEPTH-1];
reg [AW:0] wr_ptr;
reg [AW:0] rd_ptr;

assign Empty = (wr_ptr == rd_ptr);
assign Full  = (wr_ptr[AW-1:0] == rd_ptr[AW-1:0]) && (wr_ptr[AW] != rd_ptr[AW]);

always @(posedge clk or posedge Reset) begin
    if (Reset) begin
        wr_ptr <= {(AW+1){1'b0}};
    end else if (WrEn && !Full) begin
        mem[wr_ptr[AW-1:0]] <= Data;
        wr_ptr <= wr_ptr + 1'b1;
    end
end

always @(posedge clk or posedge Reset) begin
    if (Reset) begin
        rd_ptr <= {(AW+1){1'b0}};
        Q      <= 16'd0;
    end else if (RdEn && !Empty) begin
        Q      <= mem[rd_ptr[AW-1:0]];
        rd_ptr <= rd_ptr + 1'b1;
    end
end

endmodule
