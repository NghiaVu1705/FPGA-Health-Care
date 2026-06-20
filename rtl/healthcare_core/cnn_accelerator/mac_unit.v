// mac_unit.v ↔ mac_unit.py
// Một phép nhân-tích lũy INT8 × INT8 → INT32.
// Không bão hòa — việc chống tràn là trách nhiệm của bên gọi.
// Ánh xạ tới 1 DSP18 của Gowin (bộ nhân 18×18, bộ tích lũy 54 bit).
module mac_unit (
    input  signed [7:0]  weight,    // INT8 [-127, 127]
    input  signed [7:0]  act,       // INT8 [0, 127] (kích hoạt sau ReLU)
    input  signed [31:0] acc_in,    // đầu vào bộ tích lũy INT32
    output signed [31:0] acc_out    // INT32 = acc_in + weight × act
);

wire signed [15:0] product = weight * act;  // 8×8 → chính xác 16 bit
assign acc_out = acc_in + {{16{product[15]}}, product};

endmodule
