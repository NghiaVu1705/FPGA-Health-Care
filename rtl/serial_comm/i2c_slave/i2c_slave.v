// i2c_slave.v — slave I²C chế độ chuẩn (100 kHz)
// Bản đồ thanh ghi:
//   0x00: spo2_raw  (UINT8, [0..100] %)
//   0x01: temp_raw  (UINT8, 0.5°C/LSB; 72=36.0°C)
//
// Giao thức: Master ghi địa chỉ thanh ghi rồi đến dữ liệu.
// Địa chỉ slave 7 bit = I2C_ADDR (mặc định 0x48).
//
// Định thời ACK: slave kéo SDA xuống thấp trong TOÀN BỘ xung SCL thứ 9 — nó bắt
// đầu điều khiển ở cạnh xuống SCL thứ 8 (sau khi master nhả SDA), giữ
// qua mức cao SCL thứ 9, và nhả ở cạnh xuống SCL thứ 9. Do đó một master thật
// lấy mẫu ACK khi SCL ở mức cao sẽ đọc được 0. Trạng thái ACK cũng
// tiêu thụ trọn chu kỳ thứ 9, nên luồng bit của byte kế tiếp vẫn căn đúng.
module i2c_slave #(
    parameter I2C_ADDR = 7'h48
)(
    input  sys_clk,
    input  rst_n,

    // Các chân I²C
    input  scl,
    inout  sda,

    // Đầu ra thanh ghi
    output reg [7:0] spo2_raw,
    output reg [7:0] temp_raw,
    output reg       data_updated  // xung 1 chu kỳ khi có dữ liệu mới được ghi
);

// ── Đồng bộ các đầu vào I²C ───────────────────────────────────────────────────

reg scl_d0, scl_d1, scl_d2;
reg sda_d0, sda_d1, sda_d2;

always @(posedge sys_clk or negedge rst_n) begin
    if (!rst_n) begin
        scl_d0<=1'b1; scl_d1<=1'b1; scl_d2<=1'b1;
        sda_d0<=1'b1; sda_d1<=1'b1; sda_d2<=1'b1;
    end else begin
        scl_d0<=scl;   scl_d1<=scl_d0; scl_d2<=scl_d1;
        sda_d0<=sda;   sda_d1<=sda_d0; sda_d2<=sda_d1;
    end
end

wire scl_rise   = ( scl_d1 & ~scl_d2);
wire scl_fall   = (~scl_d1 &  scl_d2);
wire sda_start  = (~sda_d1 &  sda_d2 &  scl_d1);  // SDA xuống khi SCL ở mức cao
wire sda_stop   = ( sda_d1 & ~sda_d2 &  scl_d1);  // SDA lên khi SCL ở mức cao

// ── FSM ──────────────────────────────────────────────────────────────────────

localparam [2:0]
    ST_IDLE    = 3'd0,
    ST_ADDR    = 3'd1,
    ST_ACK_A   = 3'd2,
    ST_REG     = 3'd3,
    ST_ACK_R   = 3'd4,
    ST_DATA    = 3'd5,
    ST_ACK_D   = 3'd6;

reg [2:0] state;
reg [7:0] shift_reg;
reg [7:0] addr_byte;
reg [7:0] data_byte;
reg [2:0] bit_cnt;
reg [7:0] reg_addr;
reg       ack_drive;     // giữ kéo SDA xuống thấp suốt cả chu kỳ ACK (thứ 9)
reg       ack_clk_rose;  // đã thấy cạnh lên SCL thứ 9 trong một trạng thái ACK

assign sda = ack_drive ? 1'b0 : 1'bz;

// Cạnh xuống SCL thứ 9 trong trạng thái ACK (chỉ sau cạnh lên của nó): ACK xong.
wire ack_complete = ack_clk_rose && scl_fall;

always @(posedge sys_clk or negedge rst_n) begin
    if (!rst_n) begin
        state        <= ST_IDLE;
        shift_reg    <= 8'd0;
        addr_byte    <= 8'd0;
        data_byte    <= 8'd0;
        bit_cnt      <= 3'd0;
        reg_addr     <= 8'd0;
        ack_drive    <= 1'b0;
        ack_clk_rose <= 1'b0;
        data_updated <= 1'b0;
        spo2_raw     <= 8'd98;   // mặc định: SpO2=98%, Temp=36.0°C
        temp_raw     <= 8'd72;
    end else begin
        data_updated <= 1'b0;

        if (sda_start) begin
            state        <= ST_ADDR;
            bit_cnt      <= 3'd0;
            ack_drive    <= 1'b0;
            ack_clk_rose <= 1'b0;
        end else if (sda_stop) begin
            state        <= ST_IDLE;
            ack_drive    <= 1'b0;
            ack_clk_rose <= 1'b0;
        end else begin
            case (state)
                ST_IDLE: begin
                    bit_cnt <= 3'd0;
                end
                ST_ADDR: begin
                    if (scl_rise) begin
                        shift_reg <= {shift_reg[6:0], sda_d1};
                        if (bit_cnt == 3'd7) begin
                            addr_byte <= {shift_reg[6:0], sda_d1};
                            state   <= ST_ACK_A;
                            bit_cnt <= 3'd0;
                        end else begin
                            bit_cnt <= bit_cnt + 1'b1;
                        end
                    end
                end
                ST_ACK_A: begin
                    // Chỉ ACK nếu địa chỉ khớp (bỏ qua bit R/W).
                    if (scl_fall && !ack_clk_rose)
                        ack_drive <= (addr_byte[7:1] == I2C_ADDR);
                    if (scl_rise)
                        ack_clk_rose <= 1'b1;
                    if (ack_complete) begin
                        ack_drive    <= 1'b0;
                        ack_clk_rose <= 1'b0;
                        state <= (addr_byte[7:1] == I2C_ADDR) ? ST_REG : ST_IDLE;
                    end
                end
                ST_REG: begin
                    if (scl_rise) begin
                        shift_reg <= {shift_reg[6:0], sda_d1};
                        if (bit_cnt == 3'd7) begin
                            reg_addr <= {shift_reg[6:0], sda_d1};
                            state    <= ST_ACK_R;
                            bit_cnt  <= 3'd0;
                        end else begin
                            bit_cnt <= bit_cnt + 1'b1;
                        end
                    end
                end
                ST_ACK_R: begin
                    if (scl_fall && !ack_clk_rose)
                        ack_drive <= 1'b1;
                    if (scl_rise)
                        ack_clk_rose <= 1'b1;
                    if (ack_complete) begin
                        ack_drive    <= 1'b0;
                        ack_clk_rose <= 1'b0;
                        state        <= ST_DATA;
                    end
                end
                ST_DATA: begin
                    if (scl_rise) begin
                        shift_reg <= {shift_reg[6:0], sda_d1};
                        if (bit_cnt == 3'd7) begin
                            data_byte <= {shift_reg[6:0], sda_d1};
                            state <= ST_ACK_D;
                            bit_cnt <= 3'd0;
                        end else begin
                            bit_cnt <= bit_cnt + 1'b1;
                        end
                    end
                end
                ST_ACK_D: begin
                    if (scl_fall && !ack_clk_rose)
                        ack_drive <= 1'b1;
                    if (scl_rise)
                        ack_clk_rose <= 1'b1;
                    if (ack_complete) begin
                        ack_drive    <= 1'b0;
                        ack_clk_rose <= 1'b0;
                        case (reg_addr)
                            8'h00: begin
                                spo2_raw     <= data_byte;
                                data_updated <= 1'b1;
                            end
                            8'h01: begin
                                temp_raw     <= data_byte;
                                data_updated <= 1'b1;
                            end
                            default: begin
                                data_updated <= 1'b0;
                            end
                        endcase
                        state <= ST_IDLE;
                    end
                end

                default: begin
                    state        <= ST_IDLE;
                    bit_cnt      <= 3'd0;
                    shift_reg    <= 8'd0;
                    addr_byte    <= 8'd0;
                    data_byte    <= 8'd0;
                    ack_drive    <= 1'b0;
                    ack_clk_rose <= 1'b0;
                end
            endcase
        end
    end
end

endmodule
