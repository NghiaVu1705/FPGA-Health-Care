// clock_divider.v — power-of-2 clock divider
// DIV must be a power of 2 >= 2
module clock_divider #(
    parameter DIV = 2
)(
    input  clk_in,
    input  rst_n,
    output clk_out
);

localparam CNT_W = $clog2(DIV);

reg [CNT_W-1:0] cnt;

always @(posedge clk_in or negedge rst_n) begin
    if (!rst_n)
        cnt <= {CNT_W{1'b0}};
    else
        cnt <= cnt + 1'b1;
end

assign clk_out = cnt[CNT_W-1];

endmodule
