// threshold_proc.v ↔ threshold_proc.py
// Rule-based classification for SpO₂ and Temperature vital signs.
// Purely combinational — 0 cycle latency.
//
// Constants must match config.py EXACTLY (GPT 5.5 cross-check):
//   SPO2_CRITICAL=90, SPO2_ABNORMAL=95
//   TEMP_CRITICAL_H=78, TEMP_CRITICAL_L=70
//   TEMP_ABNORMAL_H=75, TEMP_ABNORMAL_L=72
(* syn_noprune = 1 *) module threshold_proc (
    input  [7:0] spo2_raw,    // UINT8, [0..100] %
    input  [7:0] temp_raw,    // UINT8, 0.5°C/LSB (72=36.0°C)

    output [1:0] spo2_class,  // 0=Normal, 1=Abnormal, 2=Critical
    output [1:0] temp_class
);

// ── Threshold constants (mirror config.py) ────────────────────────────────────
localparam [7:0] SPO2_CRITICAL   = 8'd90;
localparam [7:0] SPO2_ABNORMAL   = 8'd95;
localparam [7:0] TEMP_CRITICAL_H = 8'd78;
localparam [7:0] TEMP_CRITICAL_L = 8'd70;
localparam [7:0] TEMP_ABNORMAL_H = 8'd75;
localparam [7:0] TEMP_ABNORMAL_L = 8'd72;

// ── SpO₂ classification ───────────────────────────────────────────────────────
// Critical:  spo2 < 90
// Abnormal:  spo2 < 95  (and >= 90)
// Normal:    spo2 >= 95
assign spo2_class = (spo2_raw < SPO2_CRITICAL)  ? 2'd2 :
                    (spo2_raw < SPO2_ABNORMAL)   ? 2'd1 : 2'd0;

// ── Temperature classification ────────────────────────────────────────────────
// Critical:  temp > 78 OR temp < 70
// Abnormal:  temp > 75 OR temp < 72  (and not critical)
// Normal:    72 <= temp <= 75
assign temp_class = (temp_raw > TEMP_CRITICAL_H || temp_raw < TEMP_CRITICAL_L) ? 2'd2 :
                    (temp_raw > TEMP_ABNORMAL_H || temp_raw < TEMP_ABNORMAL_L) ? 2'd1 : 2'd0;

endmodule
