// weight_cache_512x8.v - cache trọng số CNN cục bộ được nạp từ các burst DDR3.
//
// Bộ lập lịch AI dùng chung sử dụng nó như một bộ đệm trung chuyển nhỏ:
// DDR3 -> weight_cache_512x8 -> cổng đọc BSRAM của cnn_top.
module weight_cache_512x8 (
    input            clk,
    input            rst_n,

    input            wr_en,
    input      [8:0] wr_addr,
    input      [7:0] wr_data,

    input      [8:0] rd_addr,
    output     [7:0] rd_data
);

// Đọc CÓ THANH GHI để khối này ánh xạ thành BSRAM Gowin (SDPB) thay vì một
// register file 4096-FF + mux LUT 512:1 (~4096 FF + 2705 LUT). FSM nạp của cnn_top thêm
// đúng 1 chu kỳ độ trễ tương ứng (nó đưa bsram_addr có thanh ghi, rồi khối này
// ghi kết quả đọc vào thanh ghi -> tổng cộng 2 chu kỳ; bsram_prev = load_addr-2 của FSM
// tính tới điều đó). Trọng số được prefetch DDR ghi vào và chỉ đọc sau đó, nên
// không có nguy cơ đọc-trong-khi-ghi.
(* syn_ramstyle = "block_ram" *) reg [7:0] mem [0:511];
reg [7:0] rd_data_r;

always @(posedge clk) begin
    if (rst_n && wr_en)
        mem[wr_addr] <= wr_data;
    rd_data_r <= mem[rd_addr];
end

assign rd_data = rd_data_r;

endmodule
