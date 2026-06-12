// biomed_shared_ai_system.v - time-multiplexed STFT/CNN biomedical AI core.
//
// This is the FPGA-fit direction after full 3-lane replication exceeded the
// GW5AST-138B device. A single STFT and a single CNN engine are shared across
// EEG, ECG, and EMG. Per-channel CNN weights are prefetched from DDR3 into a
// 512-byte local cache before each channel is processed.
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
    parameter [4:0]  PIPELINE_FLUSH_CYCLES = 5'd15,   // ST_RESET hold time, was magic 15
    parameter [9:0]  CNN_CACHE_LOAD_CYCLES = 10'd512, // cycles for cnn_top to load cache weights
    parameter [23:0] CNN_INFER_TIMEOUT     = 24'd1_000_000  // ST_WAIT watchdog cycles (~10ms@100MHz)
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
    output reg             cnn_timeout_error,   // ST_WAIT watchdog tripped

    output     [1:0]       final_class,
    output     [4:0]       triggered_sensors,
    output     [1:0]       confidence,
    // Pulse asserted one cycle AFTER decision_layer has updated its outputs.
    // Use this as the `src_update` for cdc_bus_handshake when bridging the
    // decision bundle into the pixel_clk domain.
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

// Synchronous pipeline clear for STFT/CNN cores.
// NOTE: This is a deliberate functional clear (not a true async reset). It is
// driven by the registered FSM state, so it is glitch-free. After DDR prefetch
// and a short reset flush, ST_CNN_LOAD releases cnn_top while samples are still
// held off, giving it time to copy the freshly prefetched cache into its local
// weight registers before STFT begins streaming spectrogram bytes.
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

// Disease-diagnosis CNN. CLASS_BITS becomes 3 for the official NUM_CLASSES=6,
// so cnn_class / the per-channel class registers below are 3-bit wide. The
// diagnostic classes are folded back to 3 severity levels by the
// *_severity_map functions before reaching decision_layer (which is unchanged).
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

// ── Severity mapper: 6 diagnostic classes -> 3 standardized severity levels ────
// Levels: 0=Normal, 1=Abnormal, 2=Critical. decision_layer keeps its 2-bit
// inputs and its majority-vote / escalation logic completely unchanged; only the
// per-channel class codes are remapped here. Tables per project spec §3.2.
//   EEG: 0->Normal; 2 (Tonic-Clonic)->Critical; {1,3,4,5}->Abnormal
//   ECG: 0->Normal; 4 (Myocardial Ischemia)->Critical; {1,2,3,5}->Abnormal
//   EMG: 0->Normal; 3 (ALS)->Critical; {1,2,4,5}->Abnormal
localparam [1:0] SEVERITY_NORMAL   = 2'd0;
localparam [1:0] SEVERITY_ABNORMAL = 2'd1;
localparam [1:0] SEVERITY_CRITICAL = 2'd2;

function [1:0] eeg_severity_map;
    input [CLASS_BITS-1:0] c;
    begin
        if (c == EEG_NORMAL_CLASS[CLASS_BITS-1:0])
            eeg_severity_map = SEVERITY_NORMAL;    // Normal Rest Awake
        else if (c == EEG_CRITICAL_CLASS[CLASS_BITS-1:0])
            eeg_severity_map = SEVERITY_CRITICAL;  // Tonic-Clonic Seizure
        else
            eeg_severity_map = SEVERITY_ABNORMAL;  // Absence / Alzheimer's / MDD / Insomnia
    end
endfunction

function [1:0] ecg_severity_map;
    input [CLASS_BITS-1:0] c;
    begin
        if (c == ECG_NORMAL_CLASS[CLASS_BITS-1:0])
            ecg_severity_map = SEVERITY_NORMAL;    // Normal Sinus Rhythm
        else if (c == ECG_CRITICAL_CLASS[CLASS_BITS-1:0])
            ecg_severity_map = SEVERITY_CRITICAL;  // Myocardial Ischemia
        else
            ecg_severity_map = SEVERITY_ABNORMAL;  // AFib / VPC / LBBB / Atrial Flutter
    end
endfunction

function [1:0] emg_severity_map;
    input [CLASS_BITS-1:0] c;
    begin
        if (c == EMG_NORMAL_CLASS[CLASS_BITS-1:0])
            emg_severity_map = SEVERITY_NORMAL;    // Normal
        else if (c == EMG_CRITICAL_CLASS[CLASS_BITS-1:0])
            emg_severity_map = SEVERITY_CRITICAL;  // ALS
        else
            emg_severity_map = SEVERITY_ABNORMAL;  // Myasthenia / Dystrophy / Polymyositis / Neuropathy
    end
endfunction

wire [1:0] eeg_severity = eeg_severity_map(eeg_class_dec);
wire [1:0] ecg_severity = ecg_severity_map(ecg_class_dec);
wire [1:0] emg_severity = emg_severity_map(emg_class_dec);

// `classes_valid_w` drives decision_layer; `decision_update` follows it by
// 1 sys_clk cycle so it pulses while final_class/triggered_sensors/confidence
// already hold their post-update values. External CDC bridges use this pulse.
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
                // Watchdog: if CNN never reports class_valid within
                // CNN_INFER_TIMEOUT cycles, raise cnn_timeout_error and
                // continue with the previous class value to avoid deadlock.
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
