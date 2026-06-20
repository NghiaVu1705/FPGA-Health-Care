// spi_slave.v — slave SPI Mode 0, khung 16 bit
// Dùng để nhận mẫu EEG (256 Hz) và ECG (500 Hz) từ ESP32.
//
// Định dạng khung: {signal_type[3:0], sample[11:0]}
//   signal_type: 4'h0 = EEG, 4'h1 = ECG
//   sample:      giá trị ADC 12 bit không dấu, ánh xạ sang INT16 qua (sample - 2048)
//
// SPI Mode 0: CPOL=0, CPHA=0 (chốt ở cạnh lên SCK, dịch ở cạnh xuống)
module spi_slave (
    input  sys_clk,
    input  rst_n,

    // Các chân SPI (từ master ESP32)
    input  spi_sck,
    input  spi_mosi,
    input  spi_cs_n,

    // Đầu ra tới FIFO
    output reg [15:0] rx_data,   // mẫu INT16 đã mở rộng dấu
    output reg        rx_valid,  // xung 1 chu kỳ khi khung hoàn tất
    output reg [1:0]  channel    // 0=EEG, 1=ECG
);

// ── Phát hiện cạnh SCK (đồng bộ về sys_clk) ──────────────────────────────────

reg sck_d0, sck_d1, sck_d2;
reg mosi_d0, mosi_d1;
reg cs_d0,  cs_d1;

always @(posedge sys_clk or negedge rst_n) begin
    if (!rst_n) begin
        sck_d0 <= 1'b0; sck_d1 <= 1'b0; sck_d2 <= 1'b0;
        mosi_d0 <= 1'b0; mosi_d1 <= 1'b0;
        cs_d0 <= 1'b1;  cs_d1 <= 1'b1;
    end else begin
        sck_d0 <= spi_sck;  sck_d1 <= sck_d0;  sck_d2 <= sck_d1;
        mosi_d0 <= spi_mosi; mosi_d1 <= mosi_d0;
        cs_d0 <= spi_cs_n;   cs_d1 <= cs_d0;
    end
end

wire sck_rise = ( sck_d1 & ~sck_d2);  // cạnh lên của SCK đã đồng bộ
wire cs_active = ~cs_d1;               // chip select tích cực mức thấp

// ── Thanh ghi dịch ────────────────────────────────────────────────────────────

reg [15:0] shift_reg;
reg  [3:0] bit_cnt;

always @(posedge sys_clk or negedge rst_n) begin
    if (!rst_n) begin
        shift_reg <= 16'd0;
        bit_cnt   <= 4'd0;
        rx_valid  <= 1'b0;
        rx_data   <= 16'd0;
        channel   <= 2'd0;
    end else begin
        rx_valid <= 1'b0;

        if (!cs_active) begin
            bit_cnt <= 4'd0;
        end else if (sck_rise) begin
            shift_reg <= {shift_reg[14:0], mosi_d1};
            if (bit_cnt == 4'd15) begin
                bit_cnt  <= 4'd0;
                // mở rộng dấu ADC 12 bit sang INT16: (adc - 2048)
                rx_data  <= $signed({1'b0, shift_reg[10:0], mosi_d1}) - $signed(16'd2048);
                channel  <= {1'b0, shift_reg[14]};  // bit14 = signal_type[0]
                rx_valid <= 1'b1;
            end else begin
                bit_cnt <= bit_cnt + 1'b1;
            end
        end
    end
end

endmodule
