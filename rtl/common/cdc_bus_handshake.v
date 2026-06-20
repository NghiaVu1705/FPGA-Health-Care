`default_nettype none
// cdc_bus_handshake.v - cầu CDC nhiều bit dùng cơ chế bắt tay bằng toggle.
//
// Dùng module này khi bus nhiều bit `src_data` được cập nhật nguyên tử (atomic) và
// miền nhận phải thấy một ảnh chụp (snapshot) nhất quán — tức là không bao giờ quan
// sát được trạng thái cập nhật dở dang do lệch pha (skew) giữa các bit như trong sơ
// đồ 2-FF theo từng bit.
//
// Nguyên lý hoạt động:
//   1. Nguồn phát một xung `src_update` rộng 1 chu kỳ khi `src_data` hợp lệ.
//   2. Nguồn chốt `src_data -> src_data_r` và đảo (toggle) thanh ghi 1 bit
//      `src_toggle` ngay trong chu kỳ đó.
//   3. `src_toggle` được đồng bộ sang miền clock đích qua bộ đồng bộ 2-FF
//      (`sync_2ff`).
//   4. Đích phát hiện cạnh trên tín hiệu toggle đã đồng bộ và lấy mẫu
//      `src_data_r` trực tiếp. Vì `src_update` phát xung thưa hơn nhiều so với
//      `dst_clk`, nên `src_data_r` gần như tĩnh (được giữ qua nhiều chu kỳ src_clk)
//      tại thời điểm đích lấy mẫu — không có nguy cơ metastability trên chính các
//      bit dữ liệu.
//   5. Đích ghi dữ liệu đã lấy mẫu vào `dst_data` và phát xung `dst_update`
//      trong một chu kỳ `dst_clk`.
//
// Ràng buộc:
//   - Nguồn phải giữ tốc độ cập nhật thấp hơn
//        f_update_max < f_dst_clk / (2 + sync_stages)
//     để không bỏ sót toggle. Với dự án này (decision_update ở sys_clk
//     tối đa ~100 MHz nhưng thực tế chỉ kích hoạt mỗi chu kỳ suy luận, ~kHz; chỉ số
//     sinh tồn cập nhật theo tốc độ I2C, ~kHz) ràng buộc này thỏa mãn rất dễ so với
//     pixel_clk (~74 MHz).
//   - `src_data_r` được xuất ra dưới dạng thanh ghi `(* syn_keep *)` để bộ tổng hợp
//     không lược bỏ nó.
//   - Trong SDC của Gowin, đường từ phía AI `src_data_r[*]` sang phía OSD `dst_data[*]`
//     nên được khai báo hoặc là `set_clock_groups -asynchronous`
//     giữa sys_clk và pixel_clk, hoặc là `set_max_delay` khớp với chu kỳ chậm
//     hơn. Xem `asic/asic_constraints.sdc` / TMDS_60HZ.sdc để biết khai báo thực
//     tế.
module cdc_bus_handshake #(
    parameter WIDTH = 8
)(
    input  wire             src_clk,
    input  wire             src_rst_n,
    input  wire [WIDTH-1:0] src_data,
    input  wire             src_update,    // xung 1 chu kỳ: dữ liệu mới sẵn sàng

    input  wire             dst_clk,
    input  wire             dst_rst_n,
    output reg  [WIDTH-1:0] dst_data,
    output reg              dst_update     // xung 1 chu kỳ: đã chốt dữ liệu mới
);

// ---- Miền nguồn: chốt dữ liệu + đảo toggle ----
(* syn_keep = 1, syn_preserve = 1 *)
reg [WIDTH-1:0] src_data_r;
(* syn_keep = 1, syn_preserve = 1 *)
reg             src_toggle;

always @(posedge src_clk or negedge src_rst_n) begin
    if (!src_rst_n) begin
        src_data_r <= {WIDTH{1'b0}};
        src_toggle <= 1'b0;
    end else if (src_update) begin
        src_data_r <= src_data;
        src_toggle <= ~src_toggle;
    end
end

// ---- Bộ đồng bộ 2-FF qua miền clock trên bit toggle ----
wire toggle_sync;
sync_2ff #(.STAGES(2), .INIT_VALUE(1'b0)) u_toggle_sync (
    .dst_clk   (dst_clk),
    .dst_rst_n (dst_rst_n),
    .async_in  (src_toggle),
    .sync_out  (toggle_sync)
);

// ---- Miền đích: phát hiện thay đổi toggle, chốt dữ liệu gần như tĩnh ----
reg toggle_sync_d;
wire toggle_edge = toggle_sync ^ toggle_sync_d;

always @(posedge dst_clk or negedge dst_rst_n) begin
    if (!dst_rst_n) begin
        toggle_sync_d <= 1'b0;
        dst_data      <= {WIDTH{1'b0}};
        dst_update    <= 1'b0;
    end else begin
        toggle_sync_d <= toggle_sync;
        dst_update    <= toggle_edge;
        if (toggle_edge)
            dst_data <= src_data_r;
    end
end

endmodule

`default_nettype wire
