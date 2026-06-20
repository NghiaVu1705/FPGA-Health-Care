// reset_sync.v — bộ đồng bộ reset bất đồng bộ dùng 2-FF
// Nhả reset một cách đồng bộ tại cạnh lên của clk.
// rst_async_n: nối với (pll_lock & button_n)
module reset_sync #(
    parameter STAGES = 2
)(
    input  clk,
    input  rst_async_n,
    output rst_sync_n
);

reg [STAGES-1:0] sync_ff;

always @(posedge clk or negedge rst_async_n) begin
    if (!rst_async_n)
        sync_ff <= {STAGES{1'b0}};
    else
        sync_ff <= {sync_ff[STAGES-2:0], 1'b1};
end

assign rst_sync_n = sync_ff[STAGES-1];

endmodule
