// stft_top.v ↔ stft_top.py
// STFT pipeline: accumulate 2048 samples → 32 hops × 64 samples
// Each hop: Hamming window → FFT 64-pt → magnitude → 32 UINT8 bins
// Output: 32×32 UINT8 spectrogram (row=time, col=frequency)
//
// Handshake:
//   Input:  sample_in (INT16) + sample_valid (1 pulse per sample @ fs)
//   Output: spec_out (32×32 = 1024 bytes, one byte per cycle)
//           spec_valid pulses for 1024 cycles when spectrogram ready
//           spec_ready from cnn_top — backpressure
module stft_top (
    input  sys_clk,
    input  rst_n,

    // Sample input (from serial_comm FIFO)
    input  signed [15:0] sample_in,
    input                sample_valid,

    // Spectrogram output (to cnn_top)
    output reg [7:0]  spec_out,
    output reg        spec_valid,
    input             spec_ready,

    // pROM interfaces (connect to gowin_ip instances in parent)
    output [5:0]  hamming_rom_addr,
    input  [7:0]  hamming_rom_data,
    output [4:0]  twiddle_rom_addr,
    input  [31:0] twiddle_rom_data
);

function [4:0] norm_shift;
    input [31:0] value;
    begin
        if      (value <= 32'd127)        norm_shift = 5'd0;
        else if (value <= 32'd128)        norm_shift = 5'd1;
        else if (value <= 32'd256)        norm_shift = 5'd2;
        else if (value <= 32'd512)        norm_shift = 5'd3;
        else if (value <= 32'd1024)       norm_shift = 5'd4;
        else if (value <= 32'd2048)       norm_shift = 5'd5;
        else if (value <= 32'd4096)       norm_shift = 5'd6;
        else if (value <= 32'd8192)       norm_shift = 5'd7;
        else if (value <= 32'd16384)      norm_shift = 5'd8;
        else if (value <= 32'd32768)      norm_shift = 5'd9;
        else if (value <= 32'd65536)      norm_shift = 5'd10;
        else if (value <= 32'd131072)     norm_shift = 5'd11;
        else if (value <= 32'd262144)     norm_shift = 5'd12;
        else if (value <= 32'd524288)     norm_shift = 5'd13;
        else if (value <= 32'd1048576)    norm_shift = 5'd14;
        else if (value <= 32'd2097152)    norm_shift = 5'd15;
        else if (value <= 32'd4194304)    norm_shift = 5'd16;
        else if (value <= 32'd8388608)    norm_shift = 5'd17;
        else if (value <= 32'd16777216)   norm_shift = 5'd18;
        else if (value <= 32'd33554432)   norm_shift = 5'd19;
        else if (value <= 32'd67108864)   norm_shift = 5'd20;
        else if (value <= 32'd134217728)  norm_shift = 5'd21;
        else if (value <= 32'd268435456)  norm_shift = 5'd22;
        else if (value <= 32'd536870912)  norm_shift = 5'd23;
        else if (value <= 32'd1073741824) norm_shift = 5'd24;
        else if (value <= 32'd2147483648) norm_shift = 5'd25;
        else                              norm_shift = 5'd26;
    end
endfunction

// ── Sample accumulation buffer (2048 INT16) ───────────────────────────────────
// syn_ramstyle forces Gowin synthesizer to infer BSRAM (2048×16 = 32K bits = 2 blocks).
// Without this attribute, GowinSynthesis maps large arrays to flip-flops → routing fail.
(* syn_ramstyle = "block_ram" *) reg signed [15:0] sample_buf [0:2047];
reg [10:0] samp_cnt;        // 0..2047
reg        buf_full;

always @(posedge sys_clk or negedge rst_n) begin
    if (!rst_n) begin
        samp_cnt <= 0; buf_full <= 0;
    end else begin
        buf_full <= 0;
        if (sample_valid) begin
            sample_buf[samp_cnt] <= sample_in;
            if (samp_cnt == 2047) begin
                samp_cnt <= 0;
                buf_full <= 1;
            end else begin
                samp_cnt <= samp_cnt + 1'b1;
            end
        end
    end
end

// ── Spectrogram buffer (32×32 UINT8) ─────────────────────────────────────────
(* syn_ramstyle = "block_ram" *) reg [7:0]  spec_buf [0:1023];

// ── STFT FSM ──────────────────────────────────────────────────────────────────
localparam [2:0]
    ST_IDLE    = 3'd0,
    ST_HAMMING = 3'd1,   // apply Hamming window to current 64-sample hop
    ST_FFT     = 3'd2,   // run FFT
    ST_MAG     = 3'd3,   // compute magnitude
    ST_NEXT    = 3'd4,   // advance hop counter
    ST_OUTPUT  = 3'd5;   // stream out 1024 bytes to cnn_top

reg [2:0] state;
reg [4:0] hop;           // 0..31 (32 hops)
reg [5:0] idx;           // sample index within hop 0..63

// ── Hamming windowed samples (64 INT16) ───────────────────────────────────────
reg signed [15:0] windowed [0:63];

// ── FFT outputs (INT32 Re/Im for 64 bins) ─────────────────────────────────────
(* syn_ramstyle = "block_ram" *) reg signed [31:0] fft_re [0:63];
(* syn_ramstyle = "block_ram" *) reg signed [31:0] fft_im [0:63];

wire signed [31:0] fft_re_serial;
wire signed [31:0] fft_im_serial;
wire               fft_bin_valid_w;
wire               fft_done;
wire [4:0]         fft_twiddle_w;
reg [5:0]          fft_feed_cnt;
reg                fft_feed_valid;
reg                fft_frame_start_r;
reg                fft_started;
reg signed [15:0]  fft_x_mux;
reg [5:0]          fft_bin_cnt;
integer            ci_fft;

// ── Magnitude outputs (UINT8 for bins 0..31) ──────────────────────────────────
reg [7:0] mag [0:31];
reg        fft_done_d;  // 1-cycle delay: aligns fft_done with state==ST_MAG

// ── Output counter ────────────────────────────────────────────────────────────
reg [9:0] out_cnt;

// ── Submodule instantiation ───────────────────────────────────────────────────
// hamming_window, fft_radix2_64, magnitude_calc are driven sequentially
// by the STFT FSM below.

// ── Inline Hamming (simple: one multiply per cycle) ──────────────────────────
reg [6:0] hw_cnt;
reg       hw_done;
reg       hw_running;
reg [10:0] sample_rd_addr;
reg signed [15:0] sample_rd_data;

assign hamming_rom_addr = hw_cnt[5:0];
wire [5:0] hw_cnt_next = hw_cnt[5:0] + 1'b1;
wire [5:0] hw_cnt_prev = hw_cnt[5:0] - 1'b1;

always @(posedge sys_clk or negedge rst_n) begin
    if (!rst_n) begin
        hw_cnt <= 0; hw_done <= 0; hw_running <= 0;
        sample_rd_addr <= 11'd0;
        sample_rd_data <= 16'sd0;
    end else begin
        hw_done <= 0;
        if (state == ST_HAMMING && !hw_running) begin
            hw_running <= 1; hw_cnt <= 0;
            sample_rd_addr <= {hop, 6'd0};
        end else if (hw_running) begin
            if (hw_cnt < 7'd63)
                sample_rd_addr <= {hop, hw_cnt_next};
            sample_rd_data <= sample_buf[sample_rd_addr];

            // 1-cycle RAM/ROM latency: apply on cycle after address
            if (hw_cnt > 0) begin
                windowed[hw_cnt_prev] <=
                    $signed(sample_rd_data) *
                    $signed({1'b0, hamming_rom_data}) >>> 8;
            end
            if (hw_cnt == 7'd64) begin
                hw_running <= 0;
                hw_done    <= 1;
            end else begin
                hw_cnt <= hw_cnt + 1'b1;
            end
        end
    end
end

// ── FFT core ─────────────────────────────────────────────────────────────────
reg fft_running;

assign twiddle_rom_addr = fft_twiddle_w;

always @(*) begin
    fft_x_mux = windowed[fft_feed_cnt];
end

fft_radix2_64 u_fft (
    .sys_clk          (sys_clk),
    .rst_n            (rst_n),
    .x_in             (fft_x_mux),
    .x_valid          (fft_feed_valid),
    .frame_start      (fft_frame_start_r),
    .re_out           (fft_re_serial),
    .im_out           (fft_im_serial),
    .bin_valid        (fft_bin_valid_w),
    .frame_done       (fft_done),
    .twiddle_addr_out (fft_twiddle_w),
    .twiddle_data     (twiddle_rom_data)
);

always @(posedge sys_clk or negedge rst_n) begin
    if (!rst_n) begin
        fft_running <= 1'b0;
        fft_started <= 1'b0;
        fft_feed_cnt <= 6'd0;
        fft_feed_valid <= 1'b0;
        fft_frame_start_r <= 1'b0;
    end else begin
        fft_feed_valid    <= 1'b0;
        fft_frame_start_r <= 1'b0;

        if (state != ST_FFT) begin
            fft_running <= 1'b0;
            fft_started <= 1'b0;
            fft_feed_cnt <= 6'd0;
        end else if (!fft_started) begin
            fft_started       <= 1'b1;
            fft_running       <= 1'b1;
            fft_feed_cnt      <= 6'd0;
            fft_frame_start_r <= 1'b1;
        end else if (fft_running) begin
            fft_feed_valid <= 1'b1;
            if (fft_feed_cnt == 6'd63) begin
                fft_running  <= 1'b0;
                fft_feed_cnt <= 6'd0;
            end else begin
                fft_feed_cnt <= fft_feed_cnt + 1'b1;
            end
        end
    end
end

always @(posedge sys_clk or negedge rst_n) begin : fft_capture
    if (!rst_n) begin
        fft_bin_cnt <= 6'd0;
        for (ci_fft = 0; ci_fft < 64; ci_fft = ci_fft+1) begin
            fft_re[ci_fft] <= 32'd0;
            fft_im[ci_fft] <= 32'd0;
        end
    end else begin
        if (fft_bin_valid_w) begin
            fft_re[fft_bin_cnt] <= fft_re_serial;
            fft_im[fft_bin_cnt] <= fft_im_serial;
            fft_bin_cnt <= fft_bin_cnt + 1'b1;
        end
        if (fft_done) begin
            fft_bin_cnt <= 6'd0;
        end
    end
end

// ── Inline magnitude (alpha-max, bins 0..31) — sequential 1 bin/cycle ────────
// CRITICAL PATH FIX: the old for-loop unrolled to 38 logic levels (28 MHz).
// Sequential version: 1 bin/cycle → ~6 logic levels → 100+ MHz achievable.
reg mag_done;
reg mag_pass1;  // Pass 1 running: compute alpha-max per bin
reg mag_pass2;  // Pass 2 running: normalize per bin
reg [4:0] mag_cnt;
reg [31:0] max_mag_r;
reg [4:0]  sh_r;
reg [31:0] tmp_r;
reg        mag_fetch_valid, mag_fetch_last;
reg        mag_calc_valid, mag_calc_last;
reg [4:0]  mag_fetch_idx, mag_calc_idx;
reg signed [31:0] mag_re_r, mag_im_r;
reg [31:0] mag_m_r;

wire [31:0] mag_abs_re_w = mag_re_r[31] ? (~mag_re_r + 32'd1) : mag_re_r;
wire [31:0] mag_abs_im_w = mag_im_r[31] ? (~mag_im_r + 32'd1) : mag_im_r;
wire [31:0] mag_mx_w     = (mag_abs_re_w >= mag_abs_im_w) ? mag_abs_re_w : mag_abs_im_w;
wire [31:0] mag_mn_w     = (mag_abs_re_w >= mag_abs_im_w) ? mag_abs_im_w : mag_abs_re_w;
wire [31:0] mag_m_w      = mag_mx_w + (mag_mn_w >> 1);
wire [31:0] max_next_w   = (mag_m_r > max_mag_r) ? mag_m_r : max_mag_r;

// fft_done (wire) fires the same cycle as ST_FFT→ST_MAG transition.
// Delay by 1 cycle so it aligns with state==ST_MAG.
always @(posedge sys_clk or negedge rst_n) begin
    if (!rst_n) fft_done_d <= 1'b0;
    else        fft_done_d <= fft_done;
end

always @(posedge sys_clk or negedge rst_n) begin
    if (!rst_n) begin
        mag_done  <= 0; mag_pass1 <= 0; mag_pass2 <= 0;
        mag_cnt   <= 0; max_mag_r <= 0;
        mag_fetch_valid <= 1'b0;
        mag_fetch_last  <= 1'b0;
        mag_calc_valid  <= 1'b0;
        mag_calc_last   <= 1'b0;
        mag_fetch_idx   <= 5'd0;
        mag_calc_idx    <= 5'd0;
        mag_re_r        <= 32'sd0;
        mag_im_r        <= 32'sd0;
        mag_m_r         <= 32'd0;
        sh_r            <= 5'd0;
        tmp_r           <= 32'd0;
    end else begin
        mag_done <= 0;

        if (state == ST_MAG && fft_done_d && !mag_pass1 && !mag_pass2) begin
            // Start Pass 1 on first cycle of ST_MAG
            mag_pass1      <= 1'b1;
            mag_cnt        <= 5'd0;
            max_mag_r      <= 32'd0;
            mag_fetch_valid <= 1'b0;
            mag_fetch_last  <= 1'b0;
            mag_calc_valid  <= 1'b0;
            mag_calc_last   <= 1'b0;
        end else if (mag_pass1) begin
            // Pass 1 pipeline:
            //   fetch FFT bin -> compute alpha-max -> update max/mag buffer.
            if (mag_calc_valid && mag_calc_last) begin
                mag[mag_calc_idx] <= mag_m_r[7:0];
                max_mag_r         <= max_next_w;
                sh_r              <= norm_shift(max_next_w);
                mag_pass1         <= 1'b0;
                mag_pass2         <= 1'b1;
                mag_cnt           <= 5'd0;
                mag_fetch_valid   <= 1'b0;
                mag_calc_valid    <= 1'b0;
            end else begin
                if (mag_calc_valid) begin
                    mag[mag_calc_idx] <= mag_m_r[7:0];
                    max_mag_r         <= max_next_w;
                end

                mag_calc_valid <= mag_fetch_valid;
                mag_calc_last  <= mag_fetch_last;
                mag_calc_idx   <= mag_fetch_idx;
                mag_m_r        <= mag_m_w;

                if (!mag_fetch_valid || !mag_fetch_last) begin
                    mag_re_r        <= fft_re[mag_cnt];
                    mag_im_r        <= fft_im[mag_cnt];
                    mag_fetch_idx   <= mag_cnt;
                    mag_fetch_last  <= (mag_cnt == 5'd31);
                    mag_fetch_valid <= 1'b1;
                    if (mag_cnt != 5'd31)
                        mag_cnt <= mag_cnt + 1'b1;
                end else begin
                    mag_fetch_valid <= 1'b0;
                end
            end
        end else if (mag_pass2) begin
            // Pass 2: one bin per cycle — normalize to [0,127]
            tmp_r = {24'd0, mag[mag_cnt]} >> sh_r;
            mag[mag_cnt] <= (tmp_r > 32'd127) ? 8'd127 : tmp_r[7:0];
            spec_buf[{hop, mag_cnt}] <= (tmp_r > 32'd127) ? 8'd127 : tmp_r[7:0];
            if (mag_cnt == 5'd31) begin
                mag_pass2 <= 0;
                mag_done  <= 1;
            end else begin
                mag_cnt <= mag_cnt + 1'b1;
            end
        end
    end
end

// ── Main STFT FSM ─────────────────────────────────────────────────────────────
always @(posedge sys_clk or negedge rst_n) begin
    if (!rst_n) begin
        state     <= ST_IDLE;
        hop       <= 0;
        spec_valid <= 0;
        out_cnt   <= 0;
    end else begin
        spec_valid <= 0;

        case (state)
            ST_IDLE: begin
                if (buf_full) begin
                    hop   <= 0;
                    state <= ST_HAMMING;
                end
            end
            ST_HAMMING: if (hw_done)  state <= ST_FFT;
            ST_FFT:     if (fft_done) state <= ST_MAG;
            ST_MAG:     if (mag_done) state <= ST_NEXT;
            ST_NEXT: begin
                if (hop == 31) begin
                    state   <= ST_OUTPUT;
                    out_cnt <= 0;
                end else begin
                    hop   <= hop + 1'b1;
                    state <= ST_HAMMING;
                end
            end
            ST_OUTPUT: begin
                if (spec_ready || !spec_valid) begin
                    spec_out   <= spec_buf[out_cnt];
                    spec_valid <= 1;
                    if (out_cnt == 1023) begin
                        state <= ST_IDLE;
                    end else begin
                        out_cnt <= out_cnt + 1'b1;
                    end
                end
            end

            default: begin
                state     <= ST_IDLE;
                hop       <= 0;
                out_cnt   <= 0;
                spec_valid <= 0;
            end
        endcase
    end
end

endmodule
