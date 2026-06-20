// biomed_shared_ai_system.v - lõi AI y sinh STFT/CNN ghép kênh theo thời gian.
//
// Đây là hướng vừa-khít-FPGA sau khi nhân bản đầy đủ 3 làn vượt quá
// thiết bị GW5AST-138B. Một STFT và một bộ máy CNN duy nhất được dùng chung cho
// EEG, ECG và EMG. Trọng số CNN theo từng kênh được prefetch từ DDR3 vào một
// cache cục bộ 512 byte trước khi xử lý mỗi kênh.
module biomed_shared_ai_system #(
    parameter integer NUM_CLASSES       = 6,
    parameter integer CLASS_BITS        = (NUM_CLASSES <= 2) ? 1 : $clog2(NUM_CLASSES),
    parameter [28:0] EEG_WEIGHT_BASE   = 29'd0,
    parameter [28:0] ECG_WEIGHT_BASE   = 29'd4096,
    parameter [28:0] EMG_WEIGHT_BASE   = 29'd8192,
    parameter [7:0]  EEG_NORMAL_CLASS  = 8'd0,
    parameter [7:0]  EEG_CRITICAL_CLASS = 8'd2,
    parameter [7:0]  ECG_NORMAL_CLASS  = 8'd0,
    parameter [7:0]  ECG_CRITICAL_CLASS = 8'd4,
    parameter [7:0]  EMG_NORMAL_CLASS  = 8'd0,
    parameter [7:0]  EMG_CRITICAL_CLASS = 8'd3,
    parameter [4:0]  PIPELINE_FLUSH_CYCLES = 5'd15,   // thời gian giữ ST_RESET, trước đây là hằng số 15
    parameter [9:0]  CNN_CACHE_LOAD_CYCLES = 10'd512, // số chu kỳ để cnn_top nạp trọng số cache
    parameter [23:0] CNN_INFER_TIMEOUT     = 24'd1_000_000  // số chu kỳ watchdog của ST_WAIT (~20ms@50MHz)
)(
    input                  sys_clk,
    input                  rst_n,

    input      signed [15:0] eeg_sample,
    input                    eeg_valid,
    output                   eeg_ready,

    input      signed [15:0] ecg_sample,
    input                    ecg_valid,
    output                   ecg_ready,

    input      signed [15:0] emg_sample,
    input                    emg_valid,
    output                   emg_ready,

    input      [7:0]       spo2_raw,
    input      [7:0]       temp_raw,
    input                  vitals_updated,

    output     [5:0]       hamming_rom_addr,
    input      [7:0]       hamming_rom_data,
    output     [4:0]       twiddle_rom_addr,
    input      [31:0]      twiddle_rom_data,

    input                  ddr_cmd_ready,
    output     [2:0]       ddr_cmd,
    output                 ddr_cmd_en,
    output     [28:0]      ddr_addr,
    input      [255:0]     ddr_rd_data,
    input                  ddr_rd_data_valid,
    input                  ddr_rd_data_end,

    output     [1:0]       active_channel,
    output                 ai_busy,
    output                 weights_ready,
    output                 weight_prefetch_error,
    output reg             cnn_timeout_error,   // watchdog của ST_WAIT đã kích hoạt

    output     [1:0]       final_class,
    output     [4:0]       triggered_sensors,
    output     [1:0]       confidence,
    // Xung được bật một chu kỳ SAU khi decision_layer đã cập nhật đầu ra của nó.
    // Dùng nó làm `src_update` cho cdc_bus_handshake khi cầu nối gói
    // quyết định sang miền pixel_clk.
    output                 decision_update
);

localparam [1:0]
    CH_EEG = 2'd0,
    CH_ECG = 2'd1,
    CH_EMG = 2'd2;

localparam [2:0]
    ST_PREFETCH = 3'd0,
    ST_RESET    = 3'd1,
    ST_CNN_LOAD = 3'd2,
    ST_COLLECT  = 3'd3,
    ST_WAIT     = 3'd4,
    ST_NEXT     = 3'd5;

reg [2:0]  state;
reg [1:0]  channel;
reg [11:0] sample_count;
reg [4:0]  reset_count;
reg [9:0]  cnn_load_count;
reg [23:0] wait_count;          // ST_WAIT watchdog
reg        prefetch_started;
reg        prefetch_start;

wire prefetch_busy;
wire prefetch_done;
wire cache_wr_en;
wire [8:0] cache_wr_addr;
wire [7:0] cache_wr_data;
wire [8:0] cache_rd_addr;
wire [7:0] cache_rd_data;

assign active_channel = channel;
assign ai_busy = (state != ST_COLLECT);
assign weights_ready = (state != ST_PREFETCH) && !prefetch_busy && !weight_prefetch_error;

function [28:0] weight_base_for_channel;
    input [1:0] ch;
    begin
        case (ch)
            CH_EEG: weight_base_for_channel = EEG_WEIGHT_BASE;
            CH_ECG: weight_base_for_channel = ECG_WEIGHT_BASE;
            default: weight_base_for_channel = EMG_WEIGHT_BASE;
        endcase
    end
endfunction

ddr3_weight_prefetcher u_weight_prefetch (
    .sys_clk           (sys_clk),
    .rst_n             (rst_n),
    .start             (prefetch_start),
    .base_addr         (weight_base_for_channel(channel)),
    .busy              (prefetch_busy),
    .done              (prefetch_done),
    .error             (weight_prefetch_error),
    .ddr_cmd_ready     (ddr_cmd_ready),
    .ddr_cmd           (ddr_cmd),
    .ddr_cmd_en        (ddr_cmd_en),
    .ddr_addr          (ddr_addr),
    .ddr_rd_data       (ddr_rd_data),
    .ddr_rd_data_valid (ddr_rd_data_valid),
    .ddr_rd_data_end   (ddr_rd_data_end),
    .cache_wr_en       (cache_wr_en),
    .cache_wr_addr     (cache_wr_addr),
    .cache_wr_data     (cache_wr_data)
);

weight_cache_512x8 u_weight_cache (
    .clk    (sys_clk),
    .rst_n  (rst_n),
    .wr_en  (cache_wr_en),
    .wr_addr(cache_wr_addr),
    .wr_data(cache_wr_data),
    .rd_addr(cache_rd_addr),
    .rd_data(cache_rd_data)
);

wire channel_is_eeg = (channel == CH_EEG);
wire channel_is_ecg = (channel == CH_ECG);
wire channel_is_emg = (channel == CH_EMG);
wire collecting = (state == ST_COLLECT) && (sample_count != 12'd2048);

assign eeg_ready = collecting && channel_is_eeg;
assign ecg_ready = collecting && channel_is_ecg;
assign emg_ready = collecting && channel_is_emg;

wire selected_valid = (channel_is_eeg && eeg_valid) ||
                      (channel_is_ecg && ecg_valid) ||
                      (channel_is_emg && emg_valid);

wire signed [15:0] selected_sample =
    channel_is_eeg ? eeg_sample :
    channel_is_ecg ? ecg_sample :
                     emg_sample;

wire sample_fire = collecting && selected_valid;

// Xóa pipeline đồng bộ cho các lõi STFT/CNN.
// LƯU Ý: Đây là phép xóa chức năng có chủ đích (không phải reset bất đồng bộ thật).
// Nó được điều khiển bởi trạng thái FSM đã ghi vào thanh ghi, nên không có nhiễu. Sau khi
// prefetch DDR và một lần flush reset ngắn, ST_CNN_LOAD nhả cnn_top trong khi mẫu vẫn
// đang bị giữ lại, cho nó thời gian sao chép cache vừa prefetch vào các thanh ghi trọng số
// cục bộ trước khi STFT bắt đầu truyền các byte spectrogram.
wire pipe_rst_n = rst_n && (state != ST_PREFETCH) && (state != ST_RESET);

wire [7:0] spec_shared;
wire       spec_shared_valid;
reg        spec_shared_valid_d;
wire       spec_shared_start = spec_shared_valid & ~spec_shared_valid_d;

stft_top u_shared_stft (
    .sys_clk         (sys_clk),
    .rst_n           (pipe_rst_n),
    .sample_in       (selected_sample),
    .sample_valid    (sample_fire),
    .spec_out        (spec_shared),
    .spec_valid      (spec_shared_valid),
    .spec_ready      (1'b1),
    .hamming_rom_addr(hamming_rom_addr),
    .hamming_rom_data(hamming_rom_data),
    .twiddle_rom_addr(twiddle_rom_addr),
    .twiddle_rom_data(twiddle_rom_data)
);

// CNN chẩn đoán bệnh. CLASS_BITS thành 3 với NUM_CLASSES=6 chính thức,
// nên cnn_class / các thanh ghi lớp theo từng kênh bên dưới rộng 3 bit. Các
// lớp chẩn đoán được gộp lại về 3 mức nghiêm trọng bởi các hàm
// *_severity_map trước khi tới decision_layer (vốn không đổi).
wire [CLASS_BITS-1:0] cnn_class;
wire       cnn_class_valid;

cnn_top #(.NUM_CLASSES(NUM_CLASSES), .CLASS_BITS(CLASS_BITS)) u_shared_cnn (
    .sys_clk    (sys_clk),
    .rst_n      (pipe_rst_n),
    .spec_in    (spec_shared),
    .spec_valid (spec_shared_valid),
    .spec_start (spec_shared_start),
    .class_out  (cnn_class),
    .class_valid(cnn_class_valid),
    .bsram_addr (cache_rd_addr),
    .bsram_data (cache_rd_data)
);

(* syn_keep = 1 *) wire [1:0] spo2_class;
(* syn_keep = 1 *) wire [1:0] temp_class;

threshold_proc u_threshold (
    .spo2_raw  (spo2_raw),
    .temp_raw  (temp_raw),
    .spo2_class(spo2_class),
    .temp_class(temp_class)
);

reg [CLASS_BITS-1:0] eeg_class_r;
reg [CLASS_BITS-1:0] ecg_class_r;
reg [CLASS_BITS-1:0] emg_class_r;

wire [CLASS_BITS-1:0] eeg_class_dec = (cnn_class_valid && channel_is_eeg) ? cnn_class : eeg_class_r;
wire [CLASS_BITS-1:0] ecg_class_dec = (cnn_class_valid && channel_is_ecg) ? cnn_class : ecg_class_r;
wire [CLASS_BITS-1:0] emg_class_dec = (cnn_class_valid && channel_is_emg) ? cnn_class : emg_class_r;

// ── Bộ ánh xạ mức nghiêm trọng: 6 lớp chẩn đoán -> 3 mức nghiêm trọng chuẩn hóa ─
// Các mức: 0=Bình thường, 1=Bất thường, 2=Nguy kịch. decision_layer giữ nguyên
// các đầu vào 2 bit và logic biểu quyết đa số / leo thang hoàn toàn không đổi; chỉ
// các mã lớp theo từng kênh được ánh xạ lại tại đây. Bảng theo đặc tả dự án §3.2.
//   EEG: 0->Bình thường; 2 (Co cứng-co giật)->Nguy kịch; {1,3,4,5}->Bất thường
//   ECG: 0->Bình thường; 4 (Thiếu máu cơ tim)->Nguy kịch; {1,2,3,5}->Bất thường
//   EMG: 0->Bình thường; 3 (ALS)->Nguy kịch; {1,2,4,5}->Bất thường
localparam [1:0] SEVERITY_NORMAL   = 2'd0;
localparam [1:0] SEVERITY_ABNORMAL = 2'd1;
localparam [1:0] SEVERITY_CRITICAL = 2'd2;

function [1:0] eeg_severity_map;
    input [CLASS_BITS-1:0] c;
    begin
        if (c == EEG_NORMAL_CLASS[CLASS_BITS-1:0])
            eeg_severity_map = SEVERITY_NORMAL;    // Nghỉ ngơi thức tỉnh bình thường
        else if (c == EEG_CRITICAL_CLASS[CLASS_BITS-1:0])
            eeg_severity_map = SEVERITY_CRITICAL;  // Động kinh co cứng-co giật
        else
            eeg_severity_map = SEVERITY_ABNORMAL;  // Vắng ý thức / Alzheimer / Trầm cảm / Mất ngủ
    end
endfunction

function [1:0] ecg_severity_map;
    input [CLASS_BITS-1:0] c;
    begin
        if (c == ECG_NORMAL_CLASS[CLASS_BITS-1:0])
            ecg_severity_map = SEVERITY_NORMAL;    // Nhịp xoang bình thường
        else if (c == ECG_CRITICAL_CLASS[CLASS_BITS-1:0])
            ecg_severity_map = SEVERITY_CRITICAL;  // Thiếu máu cơ tim
        else
            ecg_severity_map = SEVERITY_ABNORMAL;  // Rung nhĩ / Ngoại tâm thu thất / Block nhánh trái / Cuồng nhĩ
    end
endfunction

function [1:0] emg_severity_map;
    input [CLASS_BITS-1:0] c;
    begin
        if (c == EMG_NORMAL_CLASS[CLASS_BITS-1:0])
            emg_severity_map = SEVERITY_NORMAL;    // Bình thường
        else if (c == EMG_CRITICAL_CLASS[CLASS_BITS-1:0])
            emg_severity_map = SEVERITY_CRITICAL;  // ALS (Xơ cứng teo cơ một bên)
        else
            emg_severity_map = SEVERITY_ABNORMAL;  // Nhược cơ / Loạn dưỡng cơ / Viêm đa cơ / Bệnh thần kinh
    end
endfunction

wire [1:0] eeg_severity = eeg_severity_map(eeg_class_dec);
wire [1:0] ecg_severity = ecg_severity_map(ecg_class_dec);
wire [1:0] emg_severity = emg_severity_map(emg_class_dec);

// `classes_valid_w` điều khiển decision_layer; `decision_update` theo sau nó
// 1 chu kỳ sys_clk để nó phát xung khi final_class/triggered_sensors/confidence
// đã giữ giá trị sau cập nhật. Các cầu nối CDC bên ngoài dùng xung này.
wire classes_valid_w = cnn_class_valid | vitals_updated;
reg  classes_valid_d;
always @(posedge sys_clk or negedge rst_n) begin
    if (!rst_n) classes_valid_d <= 1'b0;
    else        classes_valid_d <= classes_valid_w;
end
assign decision_update = classes_valid_d;

decision_layer u_decision (
    .sys_clk          (sys_clk),
    .rst_n            (rst_n),
    .eeg_class        (eeg_severity),
    .ecg_class        (ecg_severity),
    .emg_class        (emg_severity),
    .spo2_class       (spo2_class),
    .temp_class       (temp_class),
    .classes_valid    (classes_valid_w),
    .class_out        (final_class),
    .triggered_sensors(triggered_sensors),
    .confidence       (confidence)
);

always @(posedge sys_clk or negedge rst_n) begin
    if (!rst_n) begin
        state               <= ST_PREFETCH;
        channel             <= CH_EEG;
        sample_count        <= 12'd0;
        reset_count         <= 5'd0;
        cnn_load_count      <= 10'd0;
        wait_count          <= 24'd0;
        cnn_timeout_error   <= 1'b0;
        prefetch_started    <= 1'b0;
        prefetch_start      <= 1'b0;
        spec_shared_valid_d <= 1'b0;
        eeg_class_r         <= {CLASS_BITS{1'b0}};
        ecg_class_r         <= {CLASS_BITS{1'b0}};
        emg_class_r         <= {CLASS_BITS{1'b0}};
    end else begin
        prefetch_start      <= 1'b0;
        spec_shared_valid_d <= spec_shared_valid;

        case (state)
            ST_PREFETCH: begin
                sample_count <= 12'd0;
                reset_count  <= 5'd0;
                cnn_load_count <= 10'd0;
                wait_count   <= 24'd0;
                if (!prefetch_started) begin
                    prefetch_started <= 1'b1;
                    prefetch_start   <= 1'b1;
                end else if (prefetch_done) begin
                    prefetch_started <= 1'b0;
                    state            <= ST_RESET;
                end else if (weight_prefetch_error) begin
                    prefetch_started <= 1'b0;
                    state            <= ST_NEXT;
                end
            end

            ST_RESET: begin
                reset_count <= reset_count + 1'b1;
                if (reset_count == PIPELINE_FLUSH_CYCLES)
                    state <= ST_CNN_LOAD;
            end

            ST_CNN_LOAD: begin
                if (cnn_load_count == CNN_CACHE_LOAD_CYCLES) begin
                    cnn_load_count <= 10'd0;
                    state <= ST_COLLECT;
                end else begin
                    cnn_load_count <= cnn_load_count + 1'b1;
                end
            end

            ST_COLLECT: begin
                if (sample_fire) begin
                    if (sample_count == 12'd2047) begin
                        sample_count <= 12'd2048;
                        wait_count   <= 24'd0;
                        state        <= ST_WAIT;
                    end else begin
                        sample_count <= sample_count + 1'b1;
                    end
                end
            end

            ST_WAIT: begin
                // Watchdog: nếu CNN không bao giờ báo class_valid trong vòng
                // CNN_INFER_TIMEOUT chu kỳ, bật cnn_timeout_error và
                // tiếp tục với giá trị lớp trước đó để tránh deadlock (bế tắc).
                if (cnn_class_valid) begin
                    case (channel)
                        CH_EEG: eeg_class_r <= cnn_class;
                        CH_ECG: ecg_class_r <= cnn_class;
                        default: emg_class_r <= cnn_class;
                    endcase
                    state <= ST_NEXT;
                end else if (wait_count == CNN_INFER_TIMEOUT) begin
                    cnn_timeout_error <= 1'b1;
                    state             <= ST_NEXT;
                end else begin
                    wait_count <= wait_count + 1'b1;
                end
            end

            ST_NEXT: begin
                if (channel == CH_EMG)
                    channel <= CH_EEG;
                else
                    channel <= channel + 1'b1;
                state <= ST_PREFETCH;
            end

            default: begin
                state <= ST_PREFETCH;
            end
        endcase
    end
end

endmodule
