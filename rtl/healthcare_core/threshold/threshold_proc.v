// threshold_proc.v ↔ threshold_proc.py
// Phân loại theo luật cho chỉ số sinh tồn SpO₂ và Nhiệt độ.
// Hoàn toàn tổ hợp — độ trễ 0 chu kỳ.
//
// Các hằng số phải khớp CHÍNH XÁC với config.py (đối chiếu chéo GPT 5.5):
//   SPO2_CRITICAL=90, SPO2_ABNORMAL=95
//   TEMP_CRITICAL_H=78, TEMP_CRITICAL_L=70
//   TEMP_ABNORMAL_H=75, TEMP_ABNORMAL_L=72
(* syn_noprune = 1 *) module threshold_proc (
    input  [7:0] spo2_raw,    // UINT8, [0..100] %
    input  [7:0] temp_raw,    // UINT8, 0.5°C/LSB (72=36.0°C)

    output [1:0] spo2_class,  // 0=Bình thường, 1=Bất thường, 2=Nguy kịch
    output [1:0] temp_class
);

// ── Hằng số ngưỡng (phản ánh config.py) ──────────────────────────────────────
localparam [7:0] SPO2_CRITICAL   = 8'd90;
localparam [7:0] SPO2_ABNORMAL   = 8'd95;
localparam [7:0] TEMP_CRITICAL_H = 8'd78;
localparam [7:0] TEMP_CRITICAL_L = 8'd70;
localparam [7:0] TEMP_ABNORMAL_H = 8'd75;
localparam [7:0] TEMP_ABNORMAL_L = 8'd72;

// ── Phân loại SpO₂ ────────────────────────────────────────────────────────────
// Nguy kịch:   spo2 < 90
// Bất thường:  spo2 < 95  (và >= 90)
// Bình thường: spo2 >= 95
assign spo2_class = (spo2_raw < SPO2_CRITICAL)  ? 2'd2 :
                    (spo2_raw < SPO2_ABNORMAL)   ? 2'd1 : 2'd0;

// ── Phân loại nhiệt độ ────────────────────────────────────────────────────────
// Nguy kịch:   temp > 78 HOẶC temp < 70
// Bất thường:  temp > 75 HOẶC temp < 72  (và không nguy kịch)
// Bình thường: 72 <= temp <= 75
assign temp_class = (temp_raw > TEMP_CRITICAL_H || temp_raw < TEMP_CRITICAL_L) ? 2'd2 :
                    (temp_raw > TEMP_ABNORMAL_H || temp_raw < TEMP_ABNORMAL_L) ? 2'd1 : 2'd0;

endmodule
