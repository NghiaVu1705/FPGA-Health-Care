// spi_slave.v — SPI Mode 0 slave, 16-bit frames
// Used to receive EEG (256 Hz) and ECG (500 Hz) samples from ESP32.
//
// Frame format: {signal_type[3:0], sample[11:0]}
//   signal_type: 4'h0 = EEG, 4'h1 = ECG
//   sample:      12-bit unsigned ADC value, maps to INT16 via (sample - 2048) << 4
//
// SPI Mode 0: CPOL=0, CPHA=0 (capture on rising SCK, shift on falling)
module spi_slave (
    input  sys_clk,
    input  rst_n,

    // SPI pins (from ESP32 master)
    input  spi_sck,
    input  spi_mosi,
    input  spi_cs_n,

    // Output to FIFO
    output reg [15:0] rx_data,   // sign-extended INT16 sample
    output reg        rx_valid,  // 1-cycle pulse when frame complete
    output reg [1:0]  channel    // 0=EEG, 1=ECG
);

// ── SCK edge detection (synchronize to sys_clk) ──────────────────────────────

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

wire sck_rise = ( sck_d1 & ~sck_d2);  // rising edge of synchronized SCK
wire cs_active = ~cs_d1;               // active-low chip select

// ── Shift register ────────────────────────────────────────────────────────────

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
                // sign-extend 12-bit ADC to INT16: (adc - 2048) << 4
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
