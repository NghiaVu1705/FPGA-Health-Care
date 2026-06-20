// hamming_window.v ↔ hamming_window.py
// Áp cửa sổ Hamming lên một khung 64 mẫu.
// Hệ số lưu trong pROM Gowin (gowin_bsram_hamming): depth=64, width=8, Q0.8
//   coeff[0] = coeff[63] = 0x14 (20), coeff[32] = 0xFF (255)
//
// Phép tính: windowed[n] = (sample[n] * coeff[n]) >>> 8  (dịch phải số học)
// Độ trễ: 64 + 1 chu kỳ mỗi khung (1 chu kỳ độ trễ đọc ROM)
module hamming_window (
    input  sys_clk,
    input  rst_n,

    // Đầu vào: một mẫu INT16 mỗi chu kỳ, 64 chu kỳ mỗi khung
    input  signed [15:0] sample_in,
    input                sample_valid,    // phải phát xung 64 lần mỗi khung
    input                frame_start,     // phát xung ở mẫu đầu tiên của khung

    // Đầu ra: một mẫu đã áp cửa sổ INT16 mỗi chu kỳ
    output reg signed [15:0] windowed_out,
    output reg               windowed_valid,

    // Giao diện pROM, được điều khiển bởi thực thể IP cha
    output [5:0]             rom_addr_out,
    input  [7:0]             rom_data
);

// ── Giao diện pROM ────────────────────────────────────────────────────────────
// Được khởi tạo bên ngoài (IP gowin_bsram_hamming).
// Ở đây ta điều khiển địa chỉ và đọc dữ liệu.

reg  [5:0]  rom_addr;

// ── Pipeline ──────────────────────────────────────────────────────────────────

reg signed [15:0] sample_d1;    // trễ mẫu 1 chu kỳ để khớp độ trễ ROM
reg               valid_d1;
reg [5:0]         cnt;

always @(posedge sys_clk or negedge rst_n) begin
    if (!rst_n) begin
        cnt          <= 6'd0;
        rom_addr     <= 6'd0;
        sample_d1    <= 16'd0;
        valid_d1     <= 1'b0;
        windowed_out <= 16'd0;
        windowed_valid <= 1'b0;
    end else begin
        windowed_valid <= 1'b0;

        // Tầng 1: phát địa chỉ đọc ROM = chỉ số mẫu
        if (frame_start)
            cnt <= 6'd0;

        if (sample_valid) begin
            rom_addr  <= cnt;
            sample_d1 <= sample_in;
            valid_d1  <= 1'b1;
            cnt       <= cnt + 1'b1;
        end else begin
            valid_d1  <= 1'b0;
        end

        // Tầng 2: dữ liệu ROM về sau 1 chu kỳ (đầu ra ROM có thanh ghi)
        if (valid_d1) begin
            // (INT16 * UINT8) >> 8 = INT16
            // Dùng trung gian 24 bit để tránh tràn trước khi dịch
            windowed_out   <= $signed(sample_d1 * $signed({1'b0, rom_data})) >>> 8;
            windowed_valid <= 1'b1;
        end
    end
end

// Xuất địa chỉ ROM để module cha kết nối tới IP pROM
assign rom_addr_out = rom_addr;

// Lưu ý: rom_data phải được nối từ gowin_bsram_hamming.dout trong module cha

endmodule
