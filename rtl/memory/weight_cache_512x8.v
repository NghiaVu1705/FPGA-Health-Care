// weight_cache_512x8.v - local CNN weight cache fed from DDR3 bursts.
//
// The shared AI scheduler uses this as a small staging buffer:
// DDR3 -> weight_cache_512x8 -> cnn_top BSRAM read port.
module weight_cache_512x8 (
    input            clk,
    input            rst_n,

    input            wr_en,
    input      [8:0] wr_addr,
    input      [7:0] wr_data,

    input      [8:0] rd_addr,
    output     [7:0] rd_data
);

// REGISTERED read so this maps to a Gowin BSRAM (SDPB) instead of a 4096-FF
// register file + 512:1 LUT mux (~4096 FF + 2705 LUT). cnn_top's load FSM adds the
// matching 1 extra cycle of latency (it presents bsram_addr registered, then this
// registers the read -> 2-cycle total; the FSM's bsram_prev = load_addr-2 accounts
// for it). Weights are written by the DDR prefetch and only read afterwards, so
// there is no read-during-write hazard.
(* syn_ramstyle = "block_ram" *) reg [7:0] mem [0:511];
reg [7:0] rd_data_r;

always @(posedge clk) begin
    if (rst_n && wr_en)
        mem[wr_addr] <= wr_data;
    rd_data_r <= mem[rd_addr];
end

assign rd_data = rd_data_r;

endmodule
