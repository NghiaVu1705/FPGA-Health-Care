// ddr3_weight_prefetcher.v - read a 512-byte CNN weight tile from DDR3.
//
// One CNN model is 512 bytes in the current packed image. This block issues
// 16 native DDR3 read commands, accepts 16 x 256-bit return beats, and writes
// them into a byte-addressed local cache.
module ddr3_weight_prefetcher #(
    parameter CMD_READ = 3'b001,
    parameter BEATS    = 16
)(
    input              sys_clk,
    input              rst_n,

    input              start,
    input      [28:0]  base_addr,
    output reg         busy,
    output reg         done,
    output reg         error,

    input              ddr_cmd_ready,
    output reg [2:0]   ddr_cmd,
    output reg         ddr_cmd_en,
    output reg [28:0]  ddr_addr,

    input      [255:0] ddr_rd_data,
    input              ddr_rd_data_valid,
    input              ddr_rd_data_end,

    output reg         cache_wr_en,
    output reg [8:0]   cache_wr_addr,
    output reg [7:0]   cache_wr_data
);

localparam [2:0]
    ST_IDLE  = 3'd0,
    ST_ISSUE = 3'd1,
    ST_WAIT  = 3'd2,
    ST_DRAIN = 3'd3,
    ST_DONE  = 3'd4,
    ST_ERROR = 3'd5;

reg [2:0] state;
reg [4:0] beat_idx;
reg [4:0] byte_idx;
reg [255:0] rd_buf;
reg [15:0] wait_timer;

wire last_beat = (beat_idx == (BEATS - 1));
wire [8:0] cache_addr_base = {beat_idx[3:0], 5'd0};

always @(posedge sys_clk or negedge rst_n) begin
    if (!rst_n) begin
        state             <= ST_IDLE;
        beat_idx          <= 5'd0;
        byte_idx          <= 5'd0;
        rd_buf            <= 256'd0;
        wait_timer        <= 16'd0;
        busy              <= 1'b0;
        done              <= 1'b0;
        error             <= 1'b0;
        ddr_cmd           <= CMD_READ;
        ddr_cmd_en        <= 1'b0;
        ddr_addr          <= 29'd0;
        cache_wr_en       <= 1'b0;
        cache_wr_addr     <= 9'd0;
        cache_wr_data     <= 8'd0;
    end else begin
        done        <= 1'b0;
        ddr_cmd_en  <= 1'b0;
        cache_wr_en <= 1'b0;

        case (state)
            ST_IDLE: begin
                busy       <= 1'b0;
                wait_timer <= 16'd0;
                if (start) begin
                    busy     <= 1'b1;
                    error    <= 1'b0;
                    beat_idx <= 5'd0;
                    byte_idx <= 5'd0;
                    state    <= ST_ISSUE;
                end
            end

            ST_ISSUE: begin
                if (ddr_cmd_ready) begin
                    ddr_cmd    <= CMD_READ;
                    ddr_cmd_en <= 1'b1;
                    ddr_addr   <= base_addr + {beat_idx, 5'd0};
                    wait_timer <= 16'd0;
                    state      <= ST_WAIT;
                end
            end

            ST_WAIT: begin
                wait_timer <= wait_timer + 1'b1;
                if (ddr_rd_data_valid) begin
                    rd_buf   <= ddr_rd_data;
                    byte_idx <= 5'd0;
                    state    <= ST_DRAIN;
                end else if (wait_timer == 16'hffff) begin
                    state <= ST_ERROR;
                end
            end

            ST_DRAIN: begin
                cache_wr_en   <= 1'b1;
                    cache_wr_addr <= cache_addr_base + byte_idx;
                cache_wr_data <= rd_buf[(byte_idx * 8) +: 8];

                if (byte_idx == 5'd31) begin
                    byte_idx <= 5'd0;
                    if (last_beat) begin
                        state <= ST_DONE;
                    end else begin
                        beat_idx <= beat_idx + 1'b1;
                        state    <= ST_ISSUE;
                    end
                end else begin
                    byte_idx <= byte_idx + 1'b1;
                end
            end

            ST_DONE: begin
                busy  <= 1'b0;
                done  <= 1'b1;
                state <= ST_IDLE;
            end

            ST_ERROR: begin
                busy  <= 1'b0;
                error <= 1'b1;
                state <= ST_IDLE;
            end

            default: begin
                busy  <= 1'b0;
                state <= ST_IDLE;
            end
        endcase
    end
end

endmodule
