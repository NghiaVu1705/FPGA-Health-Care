// weight_boot_loader.v - Phân tích ảnh trọng số đã đóng gói và sao chép payload vào DDR3.
// (Ghi chú Pha 8: `default_nettype none` đã bị bỏ vì danh sách cổng dùng khai báo
//  wire ngầm định; bật lại nó một cách sạch sẽ đòi hỏi gõ lại mọi cổng với
//  từ khóa `wire`/`reg` tường minh. Được theo dõi như công việc dọn dẹp RTL tương lai trong
//  docs/asic_readiness_report.md §6.)
//
// Luồng đầu vào là định dạng nhị phân do software/pack_weight_image.py sinh ra:
// header 64 byte, bảng N*64 byte, rồi các khối payload đã căn chỉnh. Header/bảng được
// kiểm tra hợp lệ, payload được sao chép theo byte vào DDR3, và CRC32 của mỗi payload được
// tính bằng phần cứng và so sánh với CRC trong manifest. Khi không khớp sẽ
// bật `crc_error` và hủy việc nạp qua nhánh ST_ERROR.
module weight_boot_loader #(
    parameter MAX_ENTRIES   = 16,
    parameter CMD_WRITE     = 3'b000,
    parameter ENFORCE_CRC32 = 1            // 1=bắt buộc, 0=chỉ phân tích (legacy)
)(
    input              sys_clk,
    input              rst_n,

    input              start,
    output reg         busy,
    output reg         done,
    output reg         error,
    output reg         crc_error,           // cờ báo CRC payload cuối không khớp

    input      [7:0]   flash_data,
    input              flash_valid,
    output             flash_ready,

    output reg         header_valid,
    output reg         entry_valid,
    output reg [15:0]  entries_loaded,
    output reg [15:0]  entry_count_out,
    output reg [31:0]  image_len_out,
    output reg [15:0]  entry_kind_out,
    output reg [31:0]  entry_flash_offset_out,
    output reg [28:0]  entry_ddr_addr_out,
    output reg [31:0]  entry_size_out,
    output reg [31:0]  entry_crc32_out,
    output     [31:0]  current_entry_flash_offset,
    output     [28:0]  current_entry_ddr_addr,
    output     [31:0]  current_entry_size,

    input              ddr_cmd_ready,
    output     [2:0]   ddr_cmd,
    output             ddr_cmd_en,
    output     [28:0]  ddr_addr,

    input              ddr_wr_data_rdy,
    output     [255:0] ddr_wr_data,
    output             ddr_wr_data_en,
    output             ddr_wr_data_end,
    output     [31:0]  ddr_wr_data_mask
);

localparam [3:0]
    ST_IDLE       = 4'd0,
    ST_HEADER     = 4'd1,
    ST_CHECK      = 4'd2,
    ST_TABLE      = 4'd3,
    ST_SKIP       = 4'd4,
    ST_START_WR   = 4'd5,
    ST_COPY       = 4'd6,
    ST_WAIT_WR    = 4'd7,
    ST_DONE       = 4'd8,
    ST_ERROR      = 4'd9;

localparam [63:0] MAGIC = 64'h3154_4757_4445_4d42; // "BMEDWGT1" little endian (đầu nhỏ)

reg [3:0] state;
reg [31:0] byte_offset;
reg [5:0] header_idx;
reg [5:0] entry_byte_idx;
reg [15:0] table_entry_idx;
reg [15:0] current_entry;
reg [31:0] payload_count;

reg [63:0] magic_r;
reg [15:0] version_r;
reg [15:0] entry_count_r;
reg [31:0] header_table_bytes_r;
reg [31:0] image_len_r;
reg [31:0] payload_crc32_r;

reg [15:0] entry_kind [0:MAX_ENTRIES-1];
reg [31:0] entry_flash_offset [0:MAX_ENTRIES-1];
reg [28:0] entry_ddr_addr [0:MAX_ENTRIES-1];
reg [31:0] entry_size [0:MAX_ENTRIES-1];
reg [31:0] entry_crc32 [0:MAX_ENTRIES-1];

reg [15:0] tmp_entry_kind;
reg [31:0] tmp_entry_flash_offset;
reg [28:0] tmp_entry_ddr_addr;
reg [31:0] tmp_entry_size;
reg [31:0] tmp_entry_crc32;

reg writer_start;
wire writer_busy;
wire writer_done;
wire writer_stream_ready;

assign current_entry_flash_offset = entry_flash_offset[current_entry];
assign current_entry_ddr_addr = entry_ddr_addr[current_entry];
assign current_entry_size = entry_size[current_entry];

wire copy_state = (state == ST_COPY);
wire writer_stream_valid = copy_state && flash_valid;
wire take_flash = flash_valid && flash_ready;

// ---- CRC32 dạng luồng trên các byte payload ----
// Được xóa ở đầu mỗi ST_START_WR (theo từng payload), cập nhật cho mỗi
// byte payload tiêu thụ trong ST_COPY. Lấy mẫu ở ST_WAIT_WR sau writer_done.
reg         crc_clear_r;
wire        crc_data_valid = copy_state && take_flash;
wire [31:0] payload_crc_w;
crc32 u_crc (
    .sys_clk    (sys_clk),
    .rst_n      (rst_n),
    .clear      (crc_clear_r),
    .data_valid (crc_data_valid),
    .data       (flash_data),
    .crc        (payload_crc_w)
);

assign flash_ready = (state == ST_HEADER) ||
                     (state == ST_TABLE) ||
                     ((state == ST_SKIP) && (byte_offset < entry_flash_offset[current_entry])) ||
                     (copy_state && writer_stream_ready);

ddr3_burst_writer #(.CMD_WRITE(CMD_WRITE)) u_writer (
    .sys_clk          (sys_clk),
    .rst_n            (rst_n),
    .start            (writer_start),
    .base_addr        (entry_ddr_addr[current_entry]),
    .byte_count       (entry_size[current_entry]),
    .busy             (writer_busy),
    .done             (writer_done),
    .stream_data      (flash_data),
    .stream_valid     (writer_stream_valid),
    .stream_ready     (writer_stream_ready),
    .ddr_cmd_ready    (ddr_cmd_ready),
    .ddr_cmd          (ddr_cmd),
    .ddr_cmd_en       (ddr_cmd_en),
    .ddr_addr         (ddr_addr),
    .ddr_wr_data_rdy  (ddr_wr_data_rdy),
    .ddr_wr_data      (ddr_wr_data),
    .ddr_wr_data_en   (ddr_wr_data_en),
    .ddr_wr_data_end  (ddr_wr_data_end),
    .ddr_wr_data_mask (ddr_wr_data_mask)
);

integer reset_i;

always @(posedge sys_clk or negedge rst_n) begin
    if (!rst_n) begin
        state                    <= ST_IDLE;
        busy                     <= 1'b0;
        done                     <= 1'b0;
        error                    <= 1'b0;
        crc_error                <= 1'b0;
        crc_clear_r              <= 1'b0;
        header_valid             <= 1'b0;
        entry_valid              <= 1'b0;
        entries_loaded           <= 16'd0;
        entry_count_out          <= 16'd0;
        image_len_out            <= 32'd0;
        entry_kind_out           <= 16'd0;
        entry_flash_offset_out   <= 32'd0;
        entry_ddr_addr_out       <= 29'd0;
        entry_size_out           <= 32'd0;
        entry_crc32_out          <= 32'd0;
        byte_offset              <= 32'd0;
        header_idx               <= 6'd0;
        entry_byte_idx           <= 6'd0;
        table_entry_idx          <= 16'd0;
        current_entry            <= 16'd0;
        payload_count            <= 32'd0;
        magic_r                  <= 64'd0;
        version_r                <= 16'd0;
        entry_count_r            <= 16'd0;
        header_table_bytes_r     <= 32'd0;
        image_len_r              <= 32'd0;
        payload_crc32_r          <= 32'd0;
        tmp_entry_kind           <= 16'd0;
        tmp_entry_flash_offset   <= 32'd0;
        tmp_entry_ddr_addr       <= 29'd0;
        tmp_entry_size           <= 32'd0;
        tmp_entry_crc32          <= 32'd0;
        writer_start             <= 1'b0;
        for (reset_i = 0; reset_i < MAX_ENTRIES; reset_i = reset_i + 1) begin
            entry_kind[reset_i]         <= 16'd0;
            entry_flash_offset[reset_i] <= 32'd0;
            entry_ddr_addr[reset_i]     <= 29'd0;
            entry_size[reset_i]         <= 32'd0;
            entry_crc32[reset_i]        <= 32'd0;
        end
    end else begin
        done         <= 1'b0;
        header_valid <= 1'b0;
        entry_valid  <= 1'b0;
        writer_start <= 1'b0;
        crc_clear_r  <= 1'b0;

        case (state)
            ST_IDLE: begin
                busy <= 1'b0;
                if (start) begin
                    busy                 <= 1'b1;
                    error                <= 1'b0;
                    crc_error            <= 1'b0;
                    entries_loaded       <= 16'd0;
                    byte_offset          <= 32'd0;
                    header_idx           <= 6'd0;
                    entry_byte_idx       <= 6'd0;
                    table_entry_idx      <= 16'd0;
                    current_entry        <= 16'd0;
                    payload_count        <= 32'd0;
                    magic_r              <= 64'd0;
                    version_r            <= 16'd0;
                    entry_count_r        <= 16'd0;
                    header_table_bytes_r <= 32'd0;
                    image_len_r          <= 32'd0;
                    payload_crc32_r      <= 32'd0;
                    tmp_entry_kind       <= 16'd0;
                    tmp_entry_flash_offset <= 32'd0;
                    tmp_entry_ddr_addr   <= 29'd0;
                    tmp_entry_size       <= 32'd0;
                    tmp_entry_crc32      <= 32'd0;
                    state                <= ST_HEADER;
                end
            end

            ST_HEADER: begin
                if (take_flash) begin
                    case (header_idx)
                        6'd0:  magic_r[7:0]    <= flash_data;
                        6'd1:  magic_r[15:8]   <= flash_data;
                        6'd2:  magic_r[23:16]  <= flash_data;
                        6'd3:  magic_r[31:24]  <= flash_data;
                        6'd4:  magic_r[39:32]  <= flash_data;
                        6'd5:  magic_r[47:40]  <= flash_data;
                        6'd6:  magic_r[55:48]  <= flash_data;
                        6'd7:  magic_r[63:56]  <= flash_data;
                        6'd8:  version_r[7:0]  <= flash_data;
                        6'd9:  version_r[15:8] <= flash_data;
                        6'd10: entry_count_r[7:0]  <= flash_data;
                        6'd11: entry_count_r[15:8] <= flash_data;
                        6'd12: header_table_bytes_r[7:0]   <= flash_data;
                        6'd13: header_table_bytes_r[15:8]  <= flash_data;
                        6'd14: header_table_bytes_r[23:16] <= flash_data;
                        6'd15: header_table_bytes_r[31:24] <= flash_data;
                        6'd16: image_len_r[7:0]   <= flash_data;
                        6'd17: image_len_r[15:8]  <= flash_data;
                        6'd18: image_len_r[23:16] <= flash_data;
                        6'd19: image_len_r[31:24] <= flash_data;
                        6'd20: payload_crc32_r[7:0]   <= flash_data;
                        6'd21: payload_crc32_r[15:8]  <= flash_data;
                        6'd22: payload_crc32_r[23:16] <= flash_data;
                        6'd23: payload_crc32_r[31:24] <= flash_data;
                        default: begin end
                    endcase

                    byte_offset <= byte_offset + 1'b1;
                    if (header_idx == 6'd63) begin
                        header_idx <= 6'd0;
                        state      <= ST_CHECK;
                    end else begin
                        header_idx <= header_idx + 1'b1;
                    end
                end
            end

            ST_CHECK: begin
                if ((magic_r != MAGIC) ||
                    (version_r != 16'd1) ||
                    (entry_count_r > MAX_ENTRIES) ||
                    (header_table_bytes_r != (32'd64 + ({16'd0, entry_count_r} << 6))) ||
                    (image_len_r < header_table_bytes_r)) begin
                    state <= ST_ERROR;
                end else begin
                    header_valid    <= 1'b1;
                    entry_count_out <= entry_count_r;
                    image_len_out   <= image_len_r;
                    if (entry_count_r == 16'd0)
                        state <= ST_DONE;
                    else
                        state <= ST_TABLE;
                end
            end

            ST_TABLE: begin
                if (take_flash) begin
                    if (entry_byte_idx == 6'd0) begin
                        tmp_entry_kind         <= 16'd0;
                        tmp_entry_flash_offset <= 32'd0;
                        tmp_entry_ddr_addr     <= 29'd0;
                        tmp_entry_size         <= 32'd0;
                        tmp_entry_crc32        <= 32'd0;
                    end

                    case (entry_byte_idx)
                        6'd16: tmp_entry_kind[7:0] <= flash_data;
                        6'd17: tmp_entry_kind[15:8] <= flash_data;
                        6'd20: tmp_entry_flash_offset[7:0] <= flash_data;
                        6'd21: tmp_entry_flash_offset[15:8] <= flash_data;
                        6'd22: tmp_entry_flash_offset[23:16] <= flash_data;
                        6'd23: tmp_entry_flash_offset[31:24] <= flash_data;
                        6'd24: tmp_entry_ddr_addr[7:0] <= flash_data;
                        6'd25: tmp_entry_ddr_addr[15:8] <= flash_data;
                        6'd26: tmp_entry_ddr_addr[23:16] <= flash_data;
                        6'd27: tmp_entry_ddr_addr[28:24] <= flash_data[4:0];
                        6'd28: tmp_entry_size[7:0] <= flash_data;
                        6'd29: tmp_entry_size[15:8] <= flash_data;
                        6'd30: tmp_entry_size[23:16] <= flash_data;
                        6'd31: tmp_entry_size[31:24] <= flash_data;
                        6'd32: tmp_entry_crc32[7:0] <= flash_data;
                        6'd33: tmp_entry_crc32[15:8] <= flash_data;
                        6'd34: tmp_entry_crc32[23:16] <= flash_data;
                        6'd35: tmp_entry_crc32[31:24] <= flash_data;
                        default: begin end
                    endcase

                    byte_offset <= byte_offset + 1'b1;
                    if (entry_byte_idx == 6'd63) begin
                        entry_valid            <= 1'b1;
                        entry_kind[table_entry_idx]         <= tmp_entry_kind;
                        entry_flash_offset[table_entry_idx] <= tmp_entry_flash_offset;
                        entry_ddr_addr[table_entry_idx]     <= tmp_entry_ddr_addr;
                        entry_size[table_entry_idx]         <= tmp_entry_size;
                        entry_crc32[table_entry_idx]        <= tmp_entry_crc32;
                        entry_kind_out         <= tmp_entry_kind;
                        entry_flash_offset_out <= tmp_entry_flash_offset;
                        entry_ddr_addr_out     <= tmp_entry_ddr_addr;
                        entry_size_out         <= tmp_entry_size;
                        entry_crc32_out        <= tmp_entry_crc32;
                        entry_byte_idx         <= 6'd0;
                        if (table_entry_idx == entry_count_r - 1'b1) begin
                            current_entry <= 16'd0;
                            state         <= ST_SKIP;
                        end else begin
                            table_entry_idx <= table_entry_idx + 1'b1;
                        end
                    end else begin
                        entry_byte_idx <= entry_byte_idx + 1'b1;
                    end
                end
            end

            ST_SKIP: begin
                if (byte_offset > entry_flash_offset[current_entry]) begin
                    state <= ST_ERROR;
                end else if (byte_offset == entry_flash_offset[current_entry]) begin
                    if (entry_size[current_entry] == 32'd0) begin
                        entries_loaded <= entries_loaded + 1'b1;
                        if (current_entry == entry_count_r - 1'b1)
                            state <= ST_DONE;
                        else begin
                            current_entry <= current_entry + 1'b1;
                            state <= ST_SKIP;
                        end
                    end else begin
                        state <= ST_START_WR;
                    end
                end else if (take_flash) begin
                    byte_offset <= byte_offset + 1'b1;
                end
            end

            ST_START_WR: begin
                payload_count <= 32'd0;
                writer_start  <= 1'b1;
                crc_clear_r   <= 1'b1;    // reset bộ tích lũy CRC cho payload mới
                state         <= ST_COPY;
            end

            ST_COPY: begin
                if (take_flash) begin
                    byte_offset   <= byte_offset + 1'b1;
                    payload_count <= payload_count + 1'b1;
                    if (payload_count == entry_size[current_entry] - 1'b1)
                        state <= ST_WAIT_WR;
                end
            end

            ST_WAIT_WR: begin
                if (writer_done) begin
                    // ---- Bắt buộc CRC theo từng payload (tùy chọn, điều khiển bằng tham số) ----
                    if (ENFORCE_CRC32 == 1 &&
                        payload_crc_w != entry_crc32[current_entry]) begin
                        crc_error <= 1'b1;
                        state     <= ST_ERROR;
                    end else begin
                        entries_loaded <= entries_loaded + 1'b1;
                        if (current_entry == entry_count_r - 1'b1) begin
                            state <= ST_DONE;
                        end else begin
                            current_entry <= current_entry + 1'b1;
                            state <= ST_SKIP;
                        end
                    end
                end
            end

            ST_DONE: begin
                busy <= 1'b0;
                done <= 1'b1;
                state <= ST_IDLE;
            end

            ST_ERROR: begin
                busy  <= 1'b0;
                error <= 1'b1;
                state <= ST_IDLE;
            end

            default: begin
                state <= ST_ERROR;
            end
        endcase
    end
end

endmodule
