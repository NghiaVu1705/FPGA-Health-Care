// Small dual-clock FIFO, parameterizable depth.
// syn_ramstyle = "block_ram" forces BSRAM inference.
// Bug fix: registered read (not combinational assign) — required for BSRAM inference.
//
// Parameters:
//   DEPTH : number of entries (power of two). Default 256 (back-compatible).
//   AW    : address width, must satisfy DEPTH == (1<<AW). Default 8.
// Pointers are AW+1 bits wide: the extra MSB is the wrap bit used to tell a
// full FIFO apart from an empty one (classic single-extra-bit scheme).
module gowin_fifo_async #(
    parameter DEPTH = 256,
    parameter AW    = 8
)(
    input         Reset,
    input         WrClk,
    input         RdClk,
    input         WrEn,
    input         RdEn,
    input  [15:0] Data,
    output reg [15:0] Q,
    output        Empty,
    output        Full
);

(* syn_ramstyle = "block_ram" *) reg [15:0] mem [0:DEPTH-1];
reg [AW:0] wr_ptr;
reg [AW:0] rd_ptr;

assign Empty = (wr_ptr == rd_ptr);
assign Full  = (wr_ptr[AW-1:0] == rd_ptr[AW-1:0]) && (wr_ptr[AW] != rd_ptr[AW]);

always @(posedge WrClk or posedge Reset) begin
    if (Reset) begin
        wr_ptr <= {(AW+1){1'b0}};
    end else if (WrEn && !Full) begin
        mem[wr_ptr[AW-1:0]] <= Data;
        wr_ptr <= wr_ptr + 1'b1;
    end
end

always @(posedge RdClk or posedge Reset) begin
    if (Reset) begin
        rd_ptr <= {(AW+1){1'b0}};
        Q      <= 16'd0;
    end else if (RdEn && !Empty) begin
        Q      <= mem[rd_ptr[AW-1:0]];
        rd_ptr <= rd_ptr + 1'b1;
    end
end

endmodule
