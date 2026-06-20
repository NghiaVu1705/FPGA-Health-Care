module uart_rx #(
    parameter integer CLK_FRE   = 50,              //MHz
    parameter integer BAUD_RATE = 115200    	   //baud
)(
	input                        clk,              
	input                        rst_n,             
	output reg[7:0]              rx_data,          //dữ liệu nối tiếp đã nhận
	output reg                   rx_data_valid,    //dữ liệu nối tiếp đã nhận hợp lệ
	input                        rx_data_ready,    //module nhận dữ liệu đã sẵn sàng
	input                        rx_pin            //đầu vào dữ liệu nối tiếp
);
localparam integer CYCLE = CLK_FRE * 1000000 / BAUD_RATE;
localparam integer CNT_W = (CYCLE <= 1) ? 1 : $clog2(CYCLE+1);

localparam [2:0] S_IDLE     = 3'd1;
localparam [2:0] S_START    = 3'd2;					//bit khởi đầu (start bit)
localparam [2:0] S_REC_BYTE = 3'd3;					//các bit dữ liệu
localparam [2:0] S_STOP     = 3'd4;					//bit kết thúc (stop bit)
localparam [2:0] S_DATA     = 3'd5;

reg [2:0]  		state, next_state;
reg        		rx_d0, rx_d1;						//độ trễ rx_pin
wire       		rx_negedge;							

reg [7:0]  		rx_bits;							
reg [CNT_W-1:0] cycle_cnt;							
reg [2:0]  		bit_cnt;							//bộ đếm bit

assign rx_negedge = rx_d1 & ~rx_d0;

// đồng bộ 2-FF
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        rx_d0 <= 1'b1;
        rx_d1 <= 1'b1;
    end else begin
        rx_d0 <= rx_pin;
        rx_d1 <= rx_d0;
    end
end

// thanh ghi trạng thái
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) state <= S_IDLE;
    else       state <= next_state;
end

// trạng thái kế tiếp
always @(*) begin
    case(state)
        S_IDLE: begin
            if(rx_negedge) next_state = S_START;
            else           next_state = S_IDLE;
        end

        // bit khởi đầu: xác nhận tại nửa-bit
        S_START: begin
            if(cycle_cnt == (CYCLE/2 - 1)) begin
                if(rx_d0 == 1'b0) next_state = S_REC_BYTE; // khởi đầu hợp lệ
                else              next_state = S_IDLE;     // nhiễu (glitch)
            end else begin
                next_state = S_START;
            end
        end

        S_REC_BYTE: begin
            if(cycle_cnt == (CYCLE - 1) && bit_cnt == 3'd7)
                next_state = S_STOP;
            else
                next_state = S_REC_BYTE;
        end

        // bit kết thúc: lấy mẫu giữa-bit; yêu cầu phải là '1'
        S_STOP: begin
            if(cycle_cnt == (CYCLE - 1)) begin
                if(rx_d0 == 1'b1) next_state = S_DATA;  // bit kết thúc tốt
                else              next_state = S_IDLE;  // lỗi khung (framing) -> bỏ
            end else begin
                next_state = S_STOP;
            end
        end

        S_DATA: begin
            if(rx_data_ready) next_state = S_IDLE;
            else              next_state = S_DATA;
        end

        default: next_state = S_IDLE;
    endcase
end

// bộ đếm chu kỳ
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        cycle_cnt <= {CNT_W{1'b0}};
    end else begin
        if(next_state != state) begin
            cycle_cnt <= {CNT_W{1'b0}};
        end else begin
            // đếm trong phạm vi trạng thái
            if(state == S_REC_BYTE) begin
                if(cycle_cnt == (CYCLE-1)) cycle_cnt <= {CNT_W{1'b0}};
                else                       cycle_cnt <= cycle_cnt + 1'b1;
            end else begin
                // với START/STOP ta chỉ cần đếm tới nửa-bit
                if(cycle_cnt == (CYCLE-1)) cycle_cnt <= {CNT_W{1'b0}};
                else                       cycle_cnt <= cycle_cnt + 1'b1;
            end
        end
    end
end

// bộ đếm bit
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        bit_cnt <= 3'd0;
    end else if(state == S_REC_BYTE) begin
        if(cycle_cnt == (CYCLE-1)) bit_cnt <= bit_cnt + 3'd1;
    end else begin
        bit_cnt <= 3'd0;
    end
end

// lấy mẫu các bit tại giữa-bit
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        rx_bits <= 8'd0;
    end
    else if(state == S_REC_BYTE && cycle_cnt == (CYCLE - 1)) begin
        rx_bits[bit_cnt] <= rx_d0;
    end
end

// chốt ra đầu ra khi vào DATA (chỉ khi bit kết thúc tốt)
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        rx_data <= 8'd0;
    end else if(state == S_STOP && next_state == S_DATA) begin
        rx_data <= rx_bits;
    end
end

// bắt tay valid
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        rx_data_valid <= 1'b0;
    end else begin
        if(state == S_STOP && next_state == S_DATA)
            rx_data_valid <= 1'b1;
        else if(state == S_DATA && rx_data_ready)
            rx_data_valid <= 1'b0;
    end
end

endmodule
