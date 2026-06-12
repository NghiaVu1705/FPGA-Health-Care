// relu_unit.v ↔ relu_unit.py
// Bounded ReLU: clip(x, 0, 127). Purely combinational.
// Mirrors clamp(0,1) from PyTorch model — INT16 input, INT16 output.
module relu_unit (
    input  signed [15:0] x_in,
    output        [15:0] y_out    // UINT portion [0, 127]
);

assign y_out = ($signed(x_in) < $signed(16'sd0))   ? 16'd0   :
               ($signed(x_in) > $signed(16'sd127))  ? 16'd127 : x_in;

endmodule
