// decision_layer.v ↔ decision_layer.py
// Quyết định bằng biểu quyết đa số từ 5 cảm biến với cửa sổ trượt N=5.
//
// Pipeline mỗi chu kỳ clock (khi classes_valid phát xung):
//  1. triggered_sensors = {eeg>0, ecg>0, emg>0, spo2>0, temp>0}
//  2. combined = max(cả 5 lớp)  — leo thang mức độ nghiêm trọng
//  3. Đẩy combined vào thanh ghi dịch 5 phần tử
//  4. Đếm số lần xuất hiện của 0/1/2 trong cửa sổ
//  5. Xuất lớp đa số (phá hòa: mức nghiêm trọng cao hơn thắng)
//  6. confidence = CAO(4-5), TRUNG BÌNH(3), THẤP(1-2)
module decision_layer (
    input  sys_clk,
    input  rst_n,

    input  [1:0] eeg_class,
    input  [1:0] ecg_class,
    input  [1:0] emg_class,
    input  [1:0] spo2_class,
    input  [1:0] temp_class,
    input        classes_valid,    // xung 1 chu kỳ mỗi chu kỳ quyết định

    output reg [1:0] class_out,          // 0=Bình thường, 1=Bất thường, 2=Nguy kịch
    output reg [4:0] triggered_sensors,  // {EEG[4],ECG[3],EMG[2],SpO₂[1],Temp[0]}
    output reg [1:0] confidence          // 0=THẤP, 1=TRUNG BÌNH, 2=CAO
);

localparam WINDOW = 5;

// ── Thanh ghi dịch cho cửa sổ trượt ──────────────────────────────────────────
reg [1:0] win [0:WINDOW-1];

// ── Các hàm trợ giúp tổ hợp ───────────────────────────────────────────────────
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

// ── Logic tuần tự ─────────────────────────────────────────────────────────────
// LƯU Ý: cnt0/cnt1/cnt2/best_cnt bên dưới là các biến tạm tổ hợp CỐ Ý
// được tính bằng gán blocking trong khối có clock này (đọc lại ngay trong
// cùng một lần đánh giá). Chỉ các đầu ra flip-flop (class_out/confidence/win) dùng
// gán non-blocking. Đừng "sửa" các gán blocking — việc đếm phụ thuộc vào nó.
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
        // 1. triggered_sensors (kết quả tổ hợp được ghi vào thanh ghi tại đây)
        triggered_sensors <= {(eeg_class_safe  > 2'd0),
                               (ecg_class_safe  > 2'd0),
                               (emg_class_safe  > 2'd0),
                               (spo2_class_safe > 2'd0),
                               (temp_class_safe > 2'd0)};

        // 2. Dịch cửa sổ: bỏ phần tử cũ nhất, đẩy combined vào
        for (k = WINDOW-1; k >= 1; k = k-1)
            win[k] <= win[k-1];
        win[0] <= combined;

        // 3. Đếm cửa sổ mới = {combined, old_win[0..3]}
        // Phép dịch non-blocking chưa có hiệu lực, nên win[k] = giá trị cũ.
        // Cửa sổ mới sau khi dịch: [combined, win[0], win[1], win[2], win[3]]
        cnt0 = 3'd0; cnt1 = 3'd0; cnt2 = 3'd0;
        for (k = 0; k < WINDOW-1; k = k+1) begin  // đếm win[0..3] cũ
            case (win[k])
                2'd0: cnt0 = cnt0 + 3'd1;
                2'd1: cnt1 = cnt1 + 3'd1;
                2'd2: cnt2 = cnt2 + 3'd1;
                default: cnt2 = cnt2 + 3'd1;
            endcase
        end
        case (combined)  // thêm đầu vào hiện tại (win[0] mới)
            2'd0: cnt0 = cnt0 + 3'd1;
            2'd1: cnt1 = cnt1 + 3'd1;
            2'd2: cnt2 = cnt2 + 3'd1;
            default: cnt2 = cnt2 + 3'd1;
        endcase

        // 4. Đa số (phá hòa: mức nghiêm trọng cao hơn thắng)
        if (cnt2 >= cnt1 && cnt2 >= cnt0) begin
            class_out <= 2'd2; best_cnt = cnt2;
        end else if (cnt1 >= cnt0) begin
            class_out <= 2'd1; best_cnt = cnt1;
        end else begin
            class_out <= 2'd0; best_cnt = cnt0;
        end

        // 5. Độ tin cậy (confidence)
        confidence <= (best_cnt >= 3'd4) ? 2'd2 :
                      (best_cnt == 3'd3) ? 2'd1 : 2'd0;
    end
end

endmodule
