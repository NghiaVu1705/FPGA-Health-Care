// decision_layer.v ↔ decision_layer.py
// 5-sensor majority-vote decision with sliding window N=5.
//
// Pipeline per clock cycle (when classes_valid pulses):
//  1. triggered_sensors = {eeg>0, ecg>0, emg>0, spo2>0, temp>0}
//  2. combined = max(all 5 classes)  — severity escalation
//  3. Push combined into 5-entry shift register
//  4. Count occurrences of 0/1/2 in window
//  5. Output majority class (tie-break: higher severity wins)
//  6. confidence = HIGH(4-5), MEDIUM(3), LOW(1-2)
module decision_layer (
    input  sys_clk,
    input  rst_n,

    input  [1:0] eeg_class,
    input  [1:0] ecg_class,
    input  [1:0] emg_class,
    input  [1:0] spo2_class,
    input  [1:0] temp_class,
    input        classes_valid,    // 1-cycle pulse per decision cycle

    output reg [1:0] class_out,          // 0=Normal, 1=Abnormal, 2=Critical
    output reg [4:0] triggered_sensors,  // {EEG[4],ECG[3],EMG[2],SpO₂[1],Temp[0]}
    output reg [1:0] confidence          // 0=LOW, 1=MEDIUM, 2=HIGH
);

localparam WINDOW = 5;

// ── Sliding window shift register ────────────────────────────────────────────
reg [1:0] win [0:WINDOW-1];

// ── Combinational helpers ─────────────────────────────────────────────────────
function [1:0] safe_class;
    input [1:0] class_in;
    begin
        case (class_in)
            2'd0: safe_class = 2'd0;
            2'd1: safe_class = 2'd1;
            2'd2: safe_class = 2'd2;
            default: safe_class = 2'd2;
        endcase
    end
endfunction

wire [1:0] eeg_class_safe  = safe_class(eeg_class);
wire [1:0] ecg_class_safe  = safe_class(ecg_class);
wire [1:0] emg_class_safe  = safe_class(emg_class);
wire [1:0] spo2_class_safe = safe_class(spo2_class);
wire [1:0] temp_class_safe = safe_class(temp_class);

wire [1:0] max01  = (eeg_class_safe  >= ecg_class_safe)  ? eeg_class_safe  : ecg_class_safe;
wire [1:0] max23  = (emg_class_safe  >= spo2_class_safe) ? emg_class_safe  : spo2_class_safe;
wire [1:0] max012 = (max01      >= max23)       ? max01      : max23;
wire [1:0] combined = (max012   >= temp_class_safe)  ? max012     : temp_class_safe;

// ── Sequential logic ──────────────────────────────────────────────────────────
always @(posedge sys_clk or negedge rst_n) begin : seq
    integer k;
    reg [2:0] cnt0, cnt1, cnt2;
    reg [2:0] best_cnt;

    if (!rst_n) begin
        for (k = 0; k < WINDOW; k = k+1)
            win[k] <= 2'd0;
        class_out         <= 2'd0;
        triggered_sensors <= 5'd0;
        confidence        <= 2'd0;
    end else if (classes_valid) begin
        // 1. triggered_sensors (combinational result registered here)
        triggered_sensors <= {(eeg_class_safe  > 2'd0),
                               (ecg_class_safe  > 2'd0),
                               (emg_class_safe  > 2'd0),
                               (spo2_class_safe > 2'd0),
                               (temp_class_safe > 2'd0)};

        // 2. Shift window: drop oldest, push combined
        for (k = WINDOW-1; k >= 1; k = k-1)
            win[k] <= win[k-1];
        win[0] <= combined;

        // 3. Count new window = {combined, old_win[0..3]}
        // Non-blocking shift hasn't taken effect yet, so win[k] = old value.
        // New window after shift: [combined, win[0], win[1], win[2], win[3]]
        cnt0 = 3'd0; cnt1 = 3'd0; cnt2 = 3'd0;
        for (k = 0; k < WINDOW-1; k = k+1) begin  // count old win[0..3]
            case (win[k])
                2'd0: cnt0 = cnt0 + 3'd1;
                2'd1: cnt1 = cnt1 + 3'd1;
                2'd2: cnt2 = cnt2 + 3'd1;
                default: cnt2 = cnt2 + 3'd1;
            endcase
        end
        case (combined)  // add current input (new win[0])
            2'd0: cnt0 = cnt0 + 3'd1;
            2'd1: cnt1 = cnt1 + 3'd1;
            2'd2: cnt2 = cnt2 + 3'd1;
            default: cnt2 = cnt2 + 3'd1;
        endcase

        // 4. Majority (tie-break: higher severity wins)
        if (cnt2 >= cnt1 && cnt2 >= cnt0) begin
            class_out <= 2'd2; best_cnt = cnt2;
        end else if (cnt1 >= cnt0) begin
            class_out <= 2'd1; best_cnt = cnt1;
        end else begin
            class_out <= 2'd0; best_cnt = cnt0;
        end

        // 5. Confidence
        confidence <= (best_cnt >= 3'd4) ? 2'd2 :
                      (best_cnt == 3'd3) ? 2'd1 : 2'd0;
    end
end

endmodule
