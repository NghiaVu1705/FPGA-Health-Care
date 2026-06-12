// i2c_slave.v — I²C standard-mode slave (100 kHz)
// Register map:
//   0x00: spo2_raw  (UINT8, [0..100] %)
//   0x01: temp_raw  (UINT8, 0.5°C/LSB; 72=36.0°C)
//
// Protocol: Master writes register address then data.
// 7-bit slave address = I2C_ADDR (default 0x48).
module i2c_slave #(
    parameter I2C_ADDR = 7'h48
)(
    input  sys_clk,
    input  rst_n,

    // I²C pins
    input  scl,
    inout  sda,

    // Register outputs
    output reg [7:0] spo2_raw,
    output reg [7:0] temp_raw,
    output reg       data_updated  // 1-cycle pulse when new data written
);

// ── Synchronize I²C inputs ────────────────────────────────────────────────────

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
wire sda_start  = (~sda_d1 &  sda_d2 &  scl_d1);  // SDA fall while SCL high
wire sda_stop   = ( sda_d1 & ~sda_d2 &  scl_d1);  // SDA rise while SCL high

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
reg       sda_oe;    // output enable (pull SDA low for ACK)

assign sda = sda_oe ? 1'b0 : 1'bz;

always @(posedge sys_clk or negedge rst_n) begin
    if (!rst_n) begin
        state       <= ST_IDLE;
        shift_reg   <= 8'd0;
        addr_byte   <= 8'd0;
        data_byte   <= 8'd0;
        bit_cnt     <= 3'd0;
        reg_addr    <= 8'd0;
        sda_oe      <= 1'b0;
        data_updated<= 1'b0;
        spo2_raw    <= 8'd98;   // default: SpO2=98%, Temp=36.0°C
        temp_raw    <= 8'd72;
    end else begin
        data_updated <= 1'b0;
        sda_oe <= 1'b0;

        if (sda_start) begin
            state   <= ST_ADDR;
            bit_cnt <= 3'd0;
        end else if (sda_stop) begin
            state <= ST_IDLE;
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
                    // ACK if address matches (ignore R/W bit)
                    if (scl_fall) begin
                        if (addr_byte[7:1] == I2C_ADDR) begin
                            sda_oe <= 1'b1;  // pull SDA low (ACK)
                            state  <= ST_REG;
                        end else begin
                            state <= ST_IDLE;
                        end
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
                    if (scl_fall) begin
                        sda_oe <= 1'b1;
                        state  <= ST_DATA;
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
                    if (scl_fall) begin
                        sda_oe <= 1'b1;
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
                    state     <= ST_IDLE;
                    bit_cnt   <= 3'd0;
                    shift_reg <= 8'd0;
                    addr_byte <= 8'd0;
                    data_byte <= 8'd0;
                    sda_oe    <= 1'b0;
                end
            endcase
        end
    end
end

endmodule
