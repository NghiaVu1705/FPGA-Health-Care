// uart_top.v — lớp bọc UART cho hệ thống y tế
// Ch0 (RX): mẫu EMG @ 1000 Hz, khung 16 bit kiểu little-endian (đầu nhỏ)
// Ch1 (TX): đầu ra console gỡ lỗi @ 115200 baud
//
// Định dạng khung (EMG RX): {0xAA, data_hi, data_lo, checksum}
//   checksum = data_hi ^ data_lo
module uart_top #(
    parameter CLK_FRE  = 100,      // MHz
    parameter BAUD_RATE = 115200
)(
    input  sys_clk,
    input  rst_n,

    // Các chân vật lý
    input  uart_rx,
    output uart_tx,

    // Đầu ra mẫu EMG (tới FIFO)
    output reg [15:0] emg_sample,
    output reg        emg_valid,

    // Đầu vào TX gỡ lỗi
    input  [7:0]  dbg_data,
    input         dbg_valid,
    output        dbg_ready
);

// ── Đường RX ─────────────────────────────────────────────────────────────────

wire [7:0] rx_data;
wire       rx_valid;
wire       rx_ready;

uart_rx #(
    .CLK_FRE  (CLK_FRE),
    .BAUD_RATE(BAUD_RATE)
) u_rx (
    .clk          (sys_clk),
    .rst_n        (rst_n),
    .rx_data      (rx_data),
    .rx_data_valid(rx_valid),
    .rx_data_ready(rx_ready),
    .rx_pin       (uart_rx)
);

// Bộ ráp lại khung: 0xAA | hi | lo | checksum → int16
localparam [1:0] F_SYNC = 2'd0, F_HI = 2'd1, F_LO = 2'd2, F_CHK = 2'd3;

reg [1:0] frame_st;
reg [7:0] byte_hi;
reg [7:0] byte_lo_r;

assign rx_ready = 1'b1;  // luôn chấp nhận byte

always @(posedge sys_clk or negedge rst_n) begin
    if (!rst_n) begin
        frame_st   <= F_SYNC;
        emg_valid  <= 1'b0;
        emg_sample <= 16'd0;
    end else begin
        emg_valid <= 1'b0;
        if (rx_valid) begin
            case (frame_st)
                F_SYNC: if (rx_data == 8'hAA)        frame_st <= F_HI;
                F_HI:   begin byte_hi <= rx_data;     frame_st <= F_LO;  end
                F_LO:   begin byte_lo_r <= rx_data;   frame_st <= F_CHK; end
                F_CHK:  begin
                    frame_st <= F_SYNC;
                    if (rx_data == (byte_hi ^ byte_lo_r)) begin
                        emg_sample <= {byte_hi, byte_lo_r};
                        emg_valid  <= 1'b1;
                    end
                end
            endcase
        end
    end
end

// ── Đường TX ─────────────────────────────────────────────────────────────────

wire tx_busy_unused;

    (* syn_noprune = 1 *) uart_tx #(
        .CLK_FRE  (CLK_FRE),
        .BAUD_RATE(BAUD_RATE)
    ) u_tx (
    .clk          (sys_clk),
    .rst_n        (rst_n),
    .tx_data      (dbg_data),
    .tx_data_valid(dbg_valid),
	    .tx_data_ready(dbg_ready),
	    .tx_pin       (uart_tx),
	    .tx_busy      (tx_busy_unused)
	);

endmodule
