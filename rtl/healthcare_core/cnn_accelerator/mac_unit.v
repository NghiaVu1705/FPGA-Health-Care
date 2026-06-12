// mac_unit.v ↔ mac_unit.py
// Single INT8 × INT8 → INT32 multiply-accumulate.
// No saturation — overflow guard is caller's responsibility.
// Maps to 1 Gowin DSP18 (18×18 multiplier, 54-bit accumulator).
module mac_unit (
    input  signed [7:0]  weight,    // INT8 [-127, 127]
    input  signed [7:0]  act,       // INT8 [0, 127] (post-ReLU activations)
    input  signed [31:0] acc_in,    // INT32 accumulator input
    output signed [31:0] acc_out    // INT32 = acc_in + weight × act
);

wire signed [15:0] product = weight * act;  // 8×8 → 16-bit exact
assign acc_out = acc_in + {{16{product[15]}}, product};

endmodule
