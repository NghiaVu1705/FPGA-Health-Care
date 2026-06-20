`default_nettype none
// sync_2ff.v - bộ đồng bộ đơn bit dùng hai flip-flop (CDC).
//
// Dùng cho các bit bất đồng bộ riêng lẻ có giá trị ổn định qua nhiều chu kỳ
// clock đích. KHÔNG dùng nhiều thực thể theo từng bit cho một bus nhiều bit cần
// cập nhật nguyên tử (atomic) — hãy dùng `cdc_bus_handshake.v` cho trường hợp
// đó.
//
// Ghi chú triển khai:
//   - Các thanh ghi theo `dst_clk` nhận đầu vào bất đồng bộ qua STAGES flip-flop.
//     STAGES=2 là mức tối thiểu theo sách giáo khoa; STAGES=3 thận trọng hơn cho
//     các miền pixel_clk / sys_clk tốc độ cao trên Gowin.
//   - Các thuộc tính tổng hợp (riêng cho Gowin) đánh dấu chuỗi này để tối ưu hóa
//     không gộp hay di chuyển các flip-flop:
//       syn_keep, syn_preserve, syn_srlstyle="registers".
//   - Reset theo kiểu bật bất đồng bộ / nhả đồng bộ trên `dst_clk`, khớp với
//     quy ước reset chung của toàn dự án.
//
// MTBF: với 2 tầng, độ thiếu tin cậy dưới mức femto-giây khi tau<<chu kỳ ở các
// tốc độ hiện đại. Xem tài liệu CDC tiêu chuẩn.
module sync_2ff #(
    parameter STAGES = 2,
    parameter INIT_VALUE = 1'b0
)(
    input  wire dst_clk,
    input  wire dst_rst_n,
    input  wire async_in,
    output wire sync_out
);

(* syn_keep = 1, syn_preserve = 1, syn_srlstyle = "registers" *)
reg [STAGES-1:0] sync_chain;

assign sync_out = sync_chain[STAGES-1];

always @(posedge dst_clk or negedge dst_rst_n) begin
    if (!dst_rst_n)
        sync_chain <= {STAGES{INIT_VALUE}};
    else
        sync_chain <= {sync_chain[STAGES-2:0], async_in};
end

endmodule

`default_nettype wire
