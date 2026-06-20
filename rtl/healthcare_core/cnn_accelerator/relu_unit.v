// relu_unit.v ↔ relu_unit.py
// ReLU có chặn: clip(x, 0, 127). Hoàn toàn tổ hợp (combinational).
// Phản ánh clamp(0,1) từ mô hình PyTorch — đầu vào INT16, đầu ra INT16.
module relu_unit (
    input  signed [15:0] x_in,
    output        [15:0] y_out    // phần UINT [0, 127]
);

assign y_out = ($signed(x_in) < $signed(16'sd0))   ? 16'd0   :
               ($signed(x_in) > $signed(16'sd127))  ? 16'd127 : x_in;

endmodule
