// text_renderer.v — lớp phủ văn bản ASCII, tỉ lệ 1x (8x16) hoặc 2x (16x32)
// Font: 8×16 điểm ảnh mỗi ký tự, ASCII 0x20..0x7E (95 ký tự), font8x16.hex.
//
// scale=0 : ô 8x16, font lấy mẫu 1:1.
// scale=1 : ô 16x32, font lấy mẫu theo dx>>1 / dy>>1 (mỗi điểm ảnh font -> 2x2).
//   Phép tính địa chỉ >>1 rất nông, nên định thời (timing) không thay đổi.
//
// Định thời: pipeline 2 chu kỳ (ROM font BSRAM có thanh ghi, rồi chọn bit + màu).
// osd_overlay làm trễ đường nền/tổng hợp để khớp (OSD_LATENCY).
module text_renderer (
    input  pixel_clk,
    input  rst_n,

    input  [11:0] hcount,
    input  [11:0] vcount,

    input  [7:0]  char_ascii,    // 0x20..0x7E
    input  [11:0] char_x,        // cột điểm ảnh góc trên-trái của ký tự
    input  [11:0] char_y,        // hàng điểm ảnh góc trên-trái của ký tự
    input         scale,         // 0 = 8x16, 1 = 16x32
    input  [23:0] fg_color,
    input  [23:0] bg_color,
    input         bg_en,

    output reg [23:0] pixel_out,
    output reg        pixel_on      // chỉ bật cho điểm ảnh thuộc nét chữ đang hiển thị
);

// ── ROM font: 95 ký tự × 16 hàng × 8 bit (BSRAM) ─────────────────────────────
(* syn_ramstyle = "block_ram" *) reg [7:0] font_rom [0:1519];

initial begin
`ifndef COCOTB_SIM
    $readmemh("font8x16.hex", font_rom);
`endif
end

// ── Tầng 0 (tổ hợp): kiểm tra ô + địa chỉ ROM ────────────────────────────────
wire [11:0] dx = hcount - char_x;
wire [11:0] dy = vcount - char_y;

wire [11:0] cell_w = scale ? 12'd16 : 12'd8;
wire [11:0] cell_h = scale ? 12'd32 : 12'd16;
wire in_cell = (hcount >= char_x) && (hcount < char_x + cell_w) &&
               (vcount >= char_y) && (vcount < char_y + cell_h);

// hàng font (0..15) và bit cột (0..7), chia đôi khi ở chế độ 2x
wire [3:0] font_row = scale ? dy[4:1] : dy[3:0];
wire [2:0] font_col = scale ? dx[3:1] : dx[2:0];

wire [6:0]  char_idx = (char_ascii >= 8'h20 && char_ascii <= 8'h7E) ?
                        char_ascii[6:0] - 7'h20 : 7'd0;
wire [10:0] rom_addr = char_idx * 16 + font_row;

// ── Tầng A: đọc BSRAM có thanh ghi + các tín hiệu điều khiển căn chỉnh ────────
reg [7:0]  row_bits_a;
reg [2:0]  col_sel_a;
reg        in_cell_a;
reg [23:0] fg_a, bg_a;
reg        bg_en_a;

always @(posedge pixel_clk or negedge rst_n) begin
    if (!rst_n) begin
        row_bits_a <= 8'd0;
        col_sel_a  <= 3'd0;
        in_cell_a  <= 1'b0;
        fg_a       <= 24'd0;
        bg_a       <= 24'd0;
        bg_en_a    <= 1'b0;
    end else begin
        row_bits_a <= font_rom[rom_addr];   // đọc ROM có thanh ghi -> BSRAM
        col_sel_a  <= font_col;
        in_cell_a  <= in_cell;
        fg_a       <= fg_color;
        bg_a       <= bg_color;
        bg_en_a    <= bg_en;
    end
end

// ── Tầng B: chọn bit + màu ───────────────────────────────────────────────────
wire bit_on = row_bits_a[7 - col_sel_a];   // MSB = điểm ảnh ngoài cùng bên trái

always @(posedge pixel_clk or negedge rst_n) begin
    if (!rst_n) begin
        pixel_out <= 24'd0;
        pixel_on  <= 1'b0;
    end else begin
        pixel_on <= in_cell_a && bit_on;
        if (in_cell_a) begin
            pixel_out <= bit_on ? fg_a :
                         bg_en_a ? bg_a : 24'd0;
        end else begin
            pixel_out <= 24'd0;
        end
    end
end

endmodule
