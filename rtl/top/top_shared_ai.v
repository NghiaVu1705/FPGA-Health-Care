// top_shared_ai.v - Tang Mega top for DDR3-backed shared AI architecture.
//
// This target keeps one STFT/CNN lane and time-multiplexes EEG/ECG/EMG. CNN
// weights are fetched from DDR3 into a small local cache before each channel.
module top_shared_ai (
    input                  clk,
    input                  rst_n,
    input                  case_next_n,

    input                  uart_rx_emg,
    output                 uart_tx_debug,

    input                  spi_sck,
    input                  spi_mosi,
    input                  spi_cs_n,

    input                  i2c_scl,
    inout                  i2c_sda,

    output [15-1:0]        ddr_addr,
    output [3-1:0]         ddr_bank,
    output                 ddr_cs,
    output                 ddr_ras,
    output                 ddr_cas,
    output                 ddr_we,
    output                 ddr_ck,
    output                 ddr_ck_n,
    output                 ddr_cke,
    output                 ddr_odt,
    output                 ddr_reset_n,
    output [4-1:0]         ddr_dm,
    inout  [32-1:0]        ddr_dq,
    inout  [4-1:0]         ddr_dqs,
    inout  [4-1:0]         ddr_dqs_n,

    output                 tmds_clk_n_0,
    output                 tmds_clk_p_0,
    output [2:0]           tmds_d_n_0,
    output [2:0]           tmds_d_p_0,

    output                 weight_load_done,
    output                 weight_load_error
);

wire sys_clk;
wire pixel_clk;
wire serial_clk;
wire pll_sys_lock;
wire pll_hdmi_lock;
wire pll_lock = pll_sys_lock & pll_hdmi_lock;

gowin_pll_sys u_pll_sys (
    .clkout0(sys_clk),
    .lock   (pll_sys_lock),
    .clkin  (clk)
);

TMDS_PLL u_tmds_pll (
    .clkin   (clk),
    .init_clk(clk),
    .clkout0 (serial_clk),
    .clkout1 (pixel_clk),
    .lock    (pll_hdmi_lock)
);

wire ddr_mem_clk;
wire ddr_pll_aux0;
wire ddr_pll_aux1;
wire ddr_pll_lock;
wire ddr_pll_stop;

Gowin_PLL u_ddr_pll (
    .clkin   (clk),
    .init_clk(clk),
    .enclk0  (1'b1),
    .enclk1  (1'b1),
    .enclk2  (1'b1),
    .clkout0 (ddr_mem_clk),
    .clkout1 (ddr_pll_aux0),
    .clkout2 (ddr_pll_aux1),
    .lock    (ddr_pll_lock),
    .reset   (~rst_n | ddr_pll_stop)
);

wire sys_rst_n;
wire pixel_rst_n;

reset_sync u_rst_sys (
    .clk        (sys_clk),
    .rst_async_n(pll_lock & rst_n),
    .rst_sync_n (sys_rst_n)
);

reset_sync u_rst_pix (
    .clk        (pixel_clk),
    .rst_async_n(pll_lock & rst_n),
    .rst_sync_n (pixel_rst_n)
);

localparam integer SAMPLE_FIFO_DEPTH = 2048;
localparam integer SAMPLE_FIFO_AW    = 11;

// ---------------------------------------------------------------------------
// Sensor ingress and per-channel FIFOs
// ---------------------------------------------------------------------------
wire [15:0] emg_sample_uart;
wire        emg_valid_uart;
reg  [7:0]  tx_data_r;
reg         tx_valid_r;
wire        tx_ready_w;

uart_top #(
    .CLK_FRE  (100),
    .BAUD_RATE(115200)
) u_uart (
    .sys_clk   (sys_clk),
    .rst_n     (sys_rst_n),
    .uart_rx   (uart_rx_emg),
    .uart_tx   (uart_tx_debug),
    .emg_sample(emg_sample_uart),
    .emg_valid (emg_valid_uart),
    .dbg_data  (tx_data_r),
    .dbg_valid (tx_valid_r),
    .dbg_ready (tx_ready_w)
);

wire [15:0] spi_sample_raw;
wire        spi_valid_raw;
wire [1:0]  spi_channel_raw;

spi_slave u_spi (
    .sys_clk  (sys_clk),
    .rst_n    (sys_rst_n),
    .spi_sck  (spi_sck),
    .spi_mosi (spi_mosi),
    .spi_cs_n (spi_cs_n),
    .rx_data  (spi_sample_raw),
    .rx_valid (spi_valid_raw),
    .channel  (spi_channel_raw)
);

wire [7:0] spo2_raw;
wire [7:0] temp_raw;
wire       vitals_updated;

i2c_slave #(.I2C_ADDR(7'h48)) u_i2c (
    .sys_clk     (sys_clk),
    .rst_n       (sys_rst_n),
    .scl         (i2c_scl),
    .sda         (i2c_sda),
    .spo2_raw    (spo2_raw),
    .temp_raw    (temp_raw),
    .data_updated(vitals_updated)
);

wire [15:0] eeg_sample;
wire [15:0] ecg_sample;
wire [15:0] emg_sample;
wire        eeg_fifo_empty, eeg_fifo_full, eeg_fifo_rd;
wire        ecg_fifo_empty, ecg_fifo_full, ecg_fifo_rd;
wire        emg_fifo_empty, emg_fifo_full, emg_fifo_rd;
wire        eeg_ready_core, ecg_ready_core, emg_ready_core;

assign eeg_fifo_rd = eeg_ready_core && !eeg_fifo_empty;
assign ecg_fifo_rd = ecg_ready_core && !ecg_fifo_empty;
assign emg_fifo_rd = emg_ready_core && !emg_fifo_empty;

// ---------------------------------------------------------------------------
// Multi-channel Signal Replay (Self-Test)
// ---------------------------------------------------------------------------
// Pressing AB13 (case_next_n, active-low w/ pull-up) replays one stored test
// window per channel (EEG/ECG/EMG) plus simulated SpO2/Temp vitals. Replayed
// samples are MUXed into the same per-channel FIFOs the live sensors feed, so
// the downstream STFT/CNN/decision pipeline is exercised end-to-end.

// --- Button debounce -> 1-cycle replay_trigger ---
reg  [1:0]  btn_sync;
reg  [15:0] btn_cnt;
reg         btn_stable;     // debounced level (1 = released)
reg         btn_stable_d;
always @(posedge sys_clk or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
        btn_sync     <= 2'b11;
        btn_cnt      <= 16'd0;
        btn_stable   <= 1'b1;
        btn_stable_d <= 1'b1;
    end else begin
        btn_sync     <= {btn_sync[0], case_next_n};
        btn_stable_d <= btn_stable;
        if (btn_sync[1] != btn_stable) begin
            if (btn_cnt == 16'hFFFF) begin
                btn_stable <= btn_sync[1];
                btn_cnt    <= 16'd0;
            end else begin
                btn_cnt <= btn_cnt + 16'd1;
            end
        end else begin
            btn_cnt <= 16'd0;
        end
    end
end
wire replay_trigger = btn_stable_d & ~btn_stable;   // falling edge = fresh press

// --- AB13 press cycles replay case: live -> case1 -> case2 -> ... -> live ---
// Each clean press advances replay_case. 0 = live sensors (replay off); 1..N play
// a stored clinical scenario (a window per channel + simulated vitals) that drives
// a distinct decision (Normal / Abnormal / Critical). Pressing past the last case
// returns to live. mode_replay is simply "a replay case is selected".
localparam integer N_REPLAY_CASES  = 3;                       // demo scenarios (excl. live)
localparam integer REPLAY_ROM_DEPTH = N_REPLAY_CASES * SAMPLE_FIFO_DEPTH;  // 3 x 2048
localparam integer REPLAY_ROM_AW    = 13;                     // ceil(log2(6144))
reg [1:0] replay_case;   // 0 = live, 1..N_REPLAY_CASES = scenario
always @(posedge sys_clk or negedge sys_rst_n) begin
    if (!sys_rst_n)          replay_case <= 2'd0;
    else if (replay_trigger) replay_case <= (replay_case == N_REPLAY_CASES[1:0]) ? 2'd0
                                                                                  : replay_case + 2'd1;
end
wire mode_replay = (replay_case != 2'd0);
// Window base within each per-channel ROM = (case-1) * 2048; live -> window 0 (unused).
wire [1:0] rep_win = mode_replay ? (replay_case - 2'd1) : 2'd0;

// --- Looping replay read pointer + FSM ---
localparam [SAMPLE_FIFO_AW-1:0] REP_LAST = SAMPLE_FIFO_DEPTH - 1;
localparam [1:0]  R_IDLE = 2'd0, R_ADDR = 2'd1, R_WRITE = 2'd2;
reg  [1:0]  rep_state;
reg  [SAMPLE_FIFO_AW-1:0] rep_addr;
reg         rep_we;               // 1-cycle write strobe shared by all 3 FIFOs
reg         vitals_updated_rep;   // single pulse when replay mode is entered

// Backpressure: only advance/write when every destination FIFO has room. With
// 2048-deep FIFOs a full per-channel frame fits, so the time-multiplexed AI core
// can drain one channel at a time without the writer dead-locking.
wire rep_fifo_ready = !eeg_fifo_full && !ecg_fifo_full && !emg_fifo_full;

always @(posedge sys_clk or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
        rep_state          <= R_IDLE;
        rep_addr           <= {SAMPLE_FIFO_AW{1'b0}};
        rep_we             <= 1'b0;
        vitals_updated_rep <= 1'b0;
    end else begin
        rep_we             <= 1'b0;
        vitals_updated_rep <= 1'b0;
        case (rep_state)
            R_IDLE: begin
                rep_addr <= {SAMPLE_FIFO_AW{1'b0}};
                if (mode_replay) begin
                    vitals_updated_rep <= 1'b1;   // latch simulated vitals once
                    rep_state          <= R_ADDR;
                end
            end
            // Present rep_addr; the registered ROM read lands one cycle later.
            R_ADDR: rep_state <= mode_replay ? R_WRITE : R_IDLE;
            // ROM data for rep_addr is valid; write one sample per channel then
            // advance, wrapping 2047->0 so the pattern repeats while mode stays on.
            R_WRITE: begin
                if (!mode_replay) begin
                    rep_state <= R_IDLE;
                end else if (rep_fifo_ready) begin
                    rep_we    <= 1'b1;
                    rep_addr  <= (rep_addr == REP_LAST) ? {SAMPLE_FIFO_AW{1'b0}} : rep_addr + 1'b1;
                    rep_state <= R_ADDR;
                end
                // else hold (rep_addr frozen -> ROM data stays valid)
            end
            default: rep_state <= R_IDLE;
        endcase
    end
end

// --- Replay sample ROMs (N_REPLAY_CASES x 2048 x 16, registered read) ---
// Each per-channel hex (extract_sample.py) is the N case windows concatenated in
// case order. The active window = {rep_win, rep_addr} (window base + sample idx).
wire [15:0] rep_eeg_data;
wire [15:0] rep_ecg_data;
wire [15:0] rep_emg_data;
wire [REPLAY_ROM_AW-1:0] rep_rom_addr = {rep_win, rep_addr};

replay_rom #(.INIT_FILE("test_eeg.hex"), .AW(REPLAY_ROM_AW), .DEPTH(REPLAY_ROM_DEPTH)) u_rom_eeg (
    .clk(sys_clk), .addr(rep_rom_addr), .dout(rep_eeg_data));
replay_rom #(.INIT_FILE("test_ecg.hex"), .AW(REPLAY_ROM_AW), .DEPTH(REPLAY_ROM_DEPTH)) u_rom_ecg (
    .clk(sys_clk), .addr(rep_rom_addr), .dout(rep_ecg_data));
replay_rom #(.INIT_FILE("test_emg.hex"), .AW(REPLAY_ROM_AW), .DEPTH(REPLAY_ROM_DEPTH)) u_rom_emg (
    .clk(sys_clk), .addr(rep_rom_addr), .dout(rep_emg_data));

// --- Live-sensor write strobes ---
wire eeg_wr_sensor = spi_valid_raw && (spi_channel_raw == 2'd0);
wire ecg_wr_sensor = spi_valid_raw && (spi_channel_raw == 2'd1);
wire emg_wr_sensor = emg_valid_uart;

// --- FIFO write MUX: replay path while mode_replay, live sensors otherwise ---
wire        eeg_wr_en   = mode_replay ? rep_we       : eeg_wr_sensor;
wire        ecg_wr_en   = mode_replay ? rep_we       : ecg_wr_sensor;
wire        emg_wr_en   = mode_replay ? rep_we       : emg_wr_sensor;
wire [15:0] eeg_wr_data = mode_replay ? rep_eeg_data : spi_sample_raw;
wire [15:0] ecg_wr_data = mode_replay ? rep_ecg_data : spi_sample_raw;
wire [15:0] emg_wr_data = mode_replay ? rep_emg_data : emg_sample_uart;

// --- Per-case simulated vitals (held while that case is selected) ---
// Chosen to reinforce each scenario's decision level (temp is 0.5C/LSB: 72=36.0C,
// 80=40.0C). Keep these in sync with CASES in software/datasets/extract_sample.py.
reg [7:0] rep_spo2, rep_temp;
always @(*) begin
    case (replay_case)
        2'd1:    begin rep_spo2 = 8'd98; rep_temp = 8'd72; end  // Normal   (97%, 36.0C)
        2'd2:    begin rep_spo2 = 8'd92; rep_temp = 8'd72; end  // Abnormal (92%, 36.0C)
        2'd3:    begin rep_spo2 = 8'd88; rep_temp = 8'd80; end  // Critical (88%, 40.0C)
        default: begin rep_spo2 = 8'd98; rep_temp = 8'd72; end
    endcase
end

// --- Vitals MUX: per-case simulated values in replay, live I2C otherwise ---
wire [7:0]  spo2_disp      = mode_replay ? rep_spo2 : spo2_raw;
wire [7:0]  temp_disp      = mode_replay ? rep_temp : temp_raw;
wire        vitals_upd_mux = mode_replay ? vitals_updated_rep : vitals_updated;

gowin_fifo_async #(.DEPTH(SAMPLE_FIFO_DEPTH), .AW(SAMPLE_FIFO_AW)) u_fifo_eeg (
    .Reset(~sys_rst_n),
    .WrClk(sys_clk),
    .RdClk(sys_clk),
    .WrEn(eeg_wr_en),
    .RdEn(eeg_fifo_rd),
    .Data(eeg_wr_data),
    .Q(eeg_sample),
    .Empty(eeg_fifo_empty),
    .Full(eeg_fifo_full)
);

gowin_fifo_async #(.DEPTH(SAMPLE_FIFO_DEPTH), .AW(SAMPLE_FIFO_AW)) u_fifo_ecg (
    .Reset(~sys_rst_n),
    .WrClk(sys_clk),
    .RdClk(sys_clk),
    .WrEn(ecg_wr_en),
    .RdEn(ecg_fifo_rd),
    .Data(ecg_wr_data),
    .Q(ecg_sample),
    .Empty(ecg_fifo_empty),
    .Full(ecg_fifo_full)
);

gowin_fifo_async #(.DEPTH(SAMPLE_FIFO_DEPTH), .AW(SAMPLE_FIFO_AW)) u_fifo_emg (
    .Reset(~sys_rst_n),
    .WrClk(sys_clk),
    .RdClk(sys_clk),
    .WrEn(emg_wr_en),
    .RdEn(emg_fifo_rd),
    .Data(emg_wr_data),
    .Q(emg_sample),
    .Empty(emg_fifo_empty),
    .Full(emg_fifo_full)
);

// ---------------------------------------------------------------------------
// DDR3 native port
// ---------------------------------------------------------------------------
wire ddr_clk_out;
wire ddr_rst_unused;
wire ddr_init_calib_complete;
wire ddr_cmd_ready;
wire [2:0] ddr_cmd_native;
wire ddr_cmd_en_native;
wire [28:0] ddr_addr_native;
wire ddr_wr_data_rdy;
wire [255:0] ddr_wr_data_native;
wire ddr_wr_data_en_native;
wire ddr_wr_data_end_native;
wire [31:0] ddr_wr_data_mask_native;
wire [255:0] ddr_rd_data;
wire ddr_rd_data_valid;
wire ddr_rd_data_end;
wire ddr_sr_ack_unused;
wire ddr_ref_ack_unused;

wire [2:0]  ddr_cmd_ai;
wire        ddr_cmd_en_ai;
wire [28:0] ddr_addr_ai;

wire [2:0]   ddr_cmd_boot;
wire         ddr_cmd_en_boot;
wire [28:0]  ddr_addr_boot;
wire [255:0] ddr_wr_data_boot;
wire         ddr_wr_data_en_boot;
wire         ddr_wr_data_end_boot;
wire [31:0]  ddr_wr_data_mask_boot;

// ---------------------------------------------------------------------------
// Boot-time Flash/ROM -> DDR3 weight loader
// ---------------------------------------------------------------------------
// Sequence: RESET -> LOAD_WEIGHTS -> WAIT_CALIB -> RUN. LOAD_WEIGHTS waits for
// DDR3 calibration before starting the CRC-checking weight_boot_loader, because
// the native DDR3 write port is not legal to use before init_calib_complete.
localparam [1:0]
    BOOT_RESET        = 2'd0,
    BOOT_LOAD_WEIGHTS = 2'd1,
    BOOT_WAIT_CALIB   = 2'd2,
    BOOT_RUN          = 2'd3;

localparam integer WEIGHT_IMAGE_BYTES = 3607;
localparam integer WEIGHT_IMAGE_AW    = 12;
localparam [WEIGHT_IMAGE_AW-1:0] WEIGHT_IMAGE_LAST = WEIGHT_IMAGE_BYTES - 1;

reg [1:0] boot_state;
reg       weight_boot_start_r;
reg       weight_boot_started;
reg       weight_flash_valid_r;
reg       weight_flash_pending;   // addr presented, waiting 1 cyc for registered ROM
reg       weight_load_done_r;
reg       weight_load_error_r;
reg [WEIGHT_IMAGE_AW-1:0] weight_flash_addr;

wire [7:0] weight_flash_data;
wire       weight_flash_ready;
wire       weight_boot_busy;
wire       weight_boot_done;
wire       weight_boot_error;
wire       weight_boot_crc_error;

assign weight_load_done  = weight_load_done_r;
assign weight_load_error = weight_load_error_r;

wire boot_run_enable = (boot_state == BOOT_RUN) && weight_load_done_r && !weight_load_error_r;

// Self-test fallback: while mode_replay is on, also release the AI core / give it
// the DDR port even if the weight boot never reached BOOT_RUN (e.g. DDR3 fails to
// calibrate on the board). This keeps the replay demo alive (pipeline runs; if DDR
// is dead the prefetch just times out per channel). mode_replay only toggles long
// after boot has finished (debounce ~64Ki cyc + human press), so there is no real
// boot-vs-AI DDR-port contention. CNN weights may be garbage in this fallback.
wire run_enable_eff      = boot_run_enable | mode_replay;
wire ddr_boot_owns_port  = !run_enable_eff;

// INIT_FILE is a BARE filename. GowinSynthesis resolves bare-name $readmemh
// relative to the .v SOURCE directory (this file -> rtl/top/), exactly like
// font8x16.hex resolves next to text_renderer.v in rtl/display/. It does NOT
// look in Final/ or the synth working dir. If the file is missing there the ROM
// init fails (EX3988) and the whole ROM is swept (NL0002) -> on the board the
// loader streams zeros and CRC fails. So keep biomed_weights.hex in rtl/top/
// (generated/copied there) AND a copy in verification/ for the cocotb sim cwd.
weight_image_rom #(
    .INIT_FILE("biomed_weights.hex"),
    .AW       (WEIGHT_IMAGE_AW),
    .DEPTH    (1 << WEIGHT_IMAGE_AW)
) u_weight_image_rom (
    .clk (sys_clk),
    .addr(weight_flash_addr),
    .dout(weight_flash_data)
);

wire        weight_header_valid_unused;
wire        weight_entry_valid_unused;
wire [15:0] weight_entries_loaded_unused;
wire [15:0] weight_entry_count_unused;
wire [31:0] weight_image_len_unused;
wire [15:0] weight_entry_kind_unused;
wire [31:0] weight_entry_flash_offset_unused;
wire [28:0] weight_entry_ddr_addr_unused;
wire [31:0] weight_entry_size_unused;
wire [31:0] weight_entry_crc32_unused;
wire [31:0] weight_current_flash_offset_unused;
wire [28:0] weight_current_ddr_addr_unused;
wire [31:0] weight_current_size_unused;

weight_boot_loader u_weight_boot_loader (
    .sys_clk                   (sys_clk),
    .rst_n                     (sys_rst_n),
    .start                     (weight_boot_start_r),
    .busy                      (weight_boot_busy),
    .done                      (weight_boot_done),
    .error                     (weight_boot_error),
    .crc_error                 (weight_boot_crc_error),
    .flash_data                (weight_flash_data),
    .flash_valid               (weight_flash_valid_r),
    .flash_ready               (weight_flash_ready),
    .header_valid              (weight_header_valid_unused),
    .entry_valid               (weight_entry_valid_unused),
    .entries_loaded            (weight_entries_loaded_unused),
    .entry_count_out           (weight_entry_count_unused),
    .image_len_out             (weight_image_len_unused),
    .entry_kind_out            (weight_entry_kind_unused),
    .entry_flash_offset_out    (weight_entry_flash_offset_unused),
    .entry_ddr_addr_out        (weight_entry_ddr_addr_unused),
    .entry_size_out            (weight_entry_size_unused),
    .entry_crc32_out           (weight_entry_crc32_unused),
    .current_entry_flash_offset(weight_current_flash_offset_unused),
    .current_entry_ddr_addr    (weight_current_ddr_addr_unused),
    .current_entry_size        (weight_current_size_unused),
    .ddr_cmd_ready             (ddr_cmd_ready && ddr_boot_owns_port),
    .ddr_cmd                   (ddr_cmd_boot),
    .ddr_cmd_en                (ddr_cmd_en_boot),
    .ddr_addr                  (ddr_addr_boot),
    .ddr_wr_data_rdy           (ddr_wr_data_rdy && ddr_boot_owns_port),
    .ddr_wr_data               (ddr_wr_data_boot),
    .ddr_wr_data_en            (ddr_wr_data_en_boot),
    .ddr_wr_data_end           (ddr_wr_data_end_boot),
    .ddr_wr_data_mask          (ddr_wr_data_mask_boot)
);

always @(posedge sys_clk or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
        boot_state           <= BOOT_RESET;
        weight_boot_start_r  <= 1'b0;
        weight_boot_started  <= 1'b0;
        weight_flash_valid_r <= 1'b0;
        weight_flash_pending <= 1'b0;
        weight_load_done_r   <= 1'b0;
        weight_load_error_r  <= 1'b0;
        weight_flash_addr    <= {WEIGHT_IMAGE_AW{1'b0}};
    end else begin
        weight_boot_start_r <= 1'b0;

        case (boot_state)
            BOOT_RESET: begin
                weight_boot_started  <= 1'b0;
                weight_flash_valid_r <= 1'b0;
                weight_flash_pending <= 1'b0;
                weight_load_done_r   <= 1'b0;
                weight_load_error_r  <= 1'b0;
                weight_flash_addr    <= {WEIGHT_IMAGE_AW{1'b0}};
                boot_state           <= BOOT_LOAD_WEIGHTS;
            end

            BOOT_LOAD_WEIGHTS: begin
                // Stream the registered ROM into the loader. Because the ROM read
                // is registered (1-cycle latency), each new address needs a
                // one-cycle `pending` bubble before its byte is valid; during
                // loader back-pressure the address holds so the ROM output (and
                // thus flash_data) stays stable.
                if (ddr_init_calib_complete) begin
                    if (!weight_boot_started) begin
                        weight_boot_started  <= 1'b1;
                        weight_boot_start_r  <= 1'b1;
                        weight_flash_addr    <= {WEIGHT_IMAGE_AW{1'b0}};
                        weight_flash_pending <= 1'b1;   // ROM data for addr 0 lands next cycle
                        weight_flash_valid_r <= 1'b0;
                    end else if (weight_flash_pending) begin
                        weight_flash_pending <= 1'b0;
                        weight_flash_valid_r <= 1'b1;   // registered ROM output now valid
                    end else if (weight_flash_valid_r && weight_flash_ready) begin
                        if (weight_flash_addr == WEIGHT_IMAGE_LAST) begin
                            weight_flash_valid_r <= 1'b0;
                        end else begin
                            weight_flash_addr    <= weight_flash_addr + 1'b1;
                            weight_flash_valid_r <= 1'b0;
                            weight_flash_pending <= 1'b1;   // wait for next ROM byte
                        end
                    end
                end

                if (weight_boot_done) begin
                    weight_load_done_r   <= 1'b1;
                    weight_flash_valid_r <= 1'b0;
                    weight_flash_pending <= 1'b0;
                    boot_state           <= BOOT_WAIT_CALIB;
                end else if (weight_boot_error) begin
                    weight_load_error_r  <= 1'b1;
                    weight_flash_valid_r <= 1'b0;
                    weight_flash_pending <= 1'b0;
                    boot_state           <= BOOT_WAIT_CALIB;
                end
            end

            BOOT_WAIT_CALIB: begin
                if (ddr_init_calib_complete && weight_load_done_r && !weight_load_error_r)
                    boot_state <= BOOT_RUN;
            end

            BOOT_RUN: begin
                if (!ddr_init_calib_complete)
                    boot_state <= BOOT_RESET;
            end

            default: boot_state <= BOOT_RESET;
        endcase
    end
end

assign ddr_cmd_native          = ddr_boot_owns_port ? ddr_cmd_boot          : ddr_cmd_ai;
assign ddr_cmd_en_native       = ddr_boot_owns_port ? ddr_cmd_en_boot       : ddr_cmd_en_ai;
assign ddr_addr_native         = ddr_boot_owns_port ? ddr_addr_boot         : ddr_addr_ai;
assign ddr_wr_data_native      = ddr_boot_owns_port ? ddr_wr_data_boot      : 256'd0;
assign ddr_wr_data_en_native   = ddr_boot_owns_port ? ddr_wr_data_en_boot   : 1'b0;
assign ddr_wr_data_end_native  = ddr_boot_owns_port ? ddr_wr_data_end_boot  : 1'b0;
assign ddr_wr_data_mask_native = ddr_boot_owns_port ? ddr_wr_data_mask_boot : 32'hffff_ffff;

DDR3MI u_ddr3 (
    .clk                (sys_clk),
    .pll_stop           (ddr_pll_stop),
    .memory_clk         (ddr_mem_clk),
    .pll_lock           (ddr_pll_lock),
    .rst_n              (sys_rst_n),
    .clk_out            (ddr_clk_out),
    .ddr_rst            (ddr_rst_unused),
    .init_calib_complete(ddr_init_calib_complete),
    .cmd_ready          (ddr_cmd_ready),
    .cmd                (ddr_cmd_native),
    .cmd_en             (ddr_cmd_en_native),
    .addr               (ddr_addr_native),
    .wr_data_rdy        (ddr_wr_data_rdy),
    .wr_data            (ddr_wr_data_native),
    .wr_data_en         (ddr_wr_data_en_native),
    .wr_data_end        (ddr_wr_data_end_native),
    .wr_data_mask       (ddr_wr_data_mask_native),
    .rd_data            (ddr_rd_data),
    .rd_data_valid      (ddr_rd_data_valid),
    .rd_data_end        (ddr_rd_data_end),
    .sr_req             (1'b0),
    .ref_req            (1'b0),
    .sr_ack             (ddr_sr_ack_unused),
    .ref_ack            (ddr_ref_ack_unused),
    .burst              (1'b1),
    .O_ddr_addr         (ddr_addr),
    .O_ddr_ba           (ddr_bank),
    .O_ddr_cs_n         (ddr_cs),
    .O_ddr_ras_n        (ddr_ras),
    .O_ddr_cas_n        (ddr_cas),
    .O_ddr_we_n         (ddr_we),
    .O_ddr_clk          (ddr_ck),
    .O_ddr_clk_n        (ddr_ck_n),
    .O_ddr_cke          (ddr_cke),
    .O_ddr_odt          (ddr_odt),
    .O_ddr_reset_n      (ddr_reset_n),
    .O_ddr_dqm          (ddr_dm),
    .IO_ddr_dq          (ddr_dq),
    .IO_ddr_dqs         (ddr_dqs),
    .IO_ddr_dqs_n       (ddr_dqs_n)
);

// ---------------------------------------------------------------------------
// Shared AI core and ROMs
// ---------------------------------------------------------------------------
wire [5:0] hamming_addr;
wire [7:0] hamming_data;
wire [4:0] twiddle_addr;
wire [31:0] twiddle_data;

gowin_bsram_hamming u_hamming_rom (
    .clk (sys_clk),
    .addr(hamming_addr),
    .dout(hamming_data)
);

gowin_bsram_twiddle u_twiddle_rom (
    .clk (sys_clk),
    .addr(twiddle_addr),
    .dout(twiddle_data)
);

wire [1:0] active_channel;
wire ai_busy;
wire weights_ready;
wire weight_prefetch_error;
wire cnn_timeout_error;
wire [1:0] final_class;
wire [4:0] triggered_sensors;
wire [1:0] confidence;
wire decision_update;
(* syn_keep = 1 *) wire ai_error_any = weight_load_error | weight_prefetch_error | cnn_timeout_error;

biomed_shared_ai_system u_shared_ai (
    .sys_clk              (sys_clk),
    .rst_n                (sys_rst_n & run_enable_eff),
    .eeg_sample           (eeg_sample),
    .eeg_valid            (eeg_fifo_rd),
    .eeg_ready            (eeg_ready_core),
    .ecg_sample           (ecg_sample),
    .ecg_valid            (ecg_fifo_rd),
    .ecg_ready            (ecg_ready_core),
    .emg_sample           (emg_sample),
    .emg_valid            (emg_fifo_rd),
    .emg_ready            (emg_ready_core),
    .spo2_raw             (spo2_disp),
    .temp_raw             (temp_disp),
    .vitals_updated       (vitals_upd_mux),
    .hamming_rom_addr     (hamming_addr),
    .hamming_rom_data     (hamming_data),
    .twiddle_rom_addr     (twiddle_addr),
    .twiddle_rom_data     (twiddle_data),
    .ddr_cmd_ready        (ddr_cmd_ready && run_enable_eff),
    .ddr_cmd              (ddr_cmd_ai),
    .ddr_cmd_en           (ddr_cmd_en_ai),
    .ddr_addr             (ddr_addr_ai),
    .ddr_rd_data          (ddr_rd_data),
    .ddr_rd_data_valid    (ddr_rd_data_valid),
    .ddr_rd_data_end      (ddr_rd_data_end),
    .active_channel       (active_channel),
    .ai_busy              (ai_busy),
    .weights_ready        (weights_ready),
    .weight_prefetch_error(weight_prefetch_error),
    .cnn_timeout_error    (cnn_timeout_error),
    .final_class          (final_class),
    .triggered_sensors    (triggered_sensors),
    .confidence           (confidence),
    .decision_update      (decision_update)
);

// ---------------------------------------------------------------------------
// Phase 5d: Clock-domain crossing AI (sys_clk) -> Display (pixel_clk)
// ---------------------------------------------------------------------------
// The OSD overlay runs in pixel_clk. All AI status signals come from sys_clk.
// Bridging directly into u_osd inputs creates a same-clock-name analysis
// (worst case under sys_clk constraint) with deep fan-out paths
// `state[*] -> OSD r/g/b outputs`. Phase 5d inserts proper synchronizers so
// every signal arriving at u_osd is already in the pixel_clk domain.
//
// Bus type        | CDC primitive       | Atomicity guarantee
// ----------------|---------------------|---------------------
// Decision bundle | cdc_bus_handshake   | YES — bundle latched on src_update,
//   (9-bit)       |                     |   sampled by dst on toggle edge
// Status flags    | sync_2ff (per bit)  | bits are independent; momentary
//   (1-bit each)  |                     |   inconsistency between flags is OK
// Vital signs     | sync_2ff (per bit)  | I2C updates a whole byte per write
//   (8-bit each)  |                     |   but pixel-rate display is ms-scale
//                 |                     |   so brief bit-skew is invisible

wire [8:0] decision_bundle_src = {final_class, triggered_sensors, confidence};
wire [8:0] decision_bundle_pix;
wire       decision_pulse_pix;   // unused but kept in case OSD wants to flash

cdc_bus_handshake #(.WIDTH(9)) u_cdc_decision (
    .src_clk    (sys_clk),
    .src_rst_n  (sys_rst_n),
    .src_data   (decision_bundle_src),
    .src_update (decision_update),
    .dst_clk    (pixel_clk),
    .dst_rst_n  (pixel_rst_n),
    .dst_data   (decision_bundle_pix),
    .dst_update (decision_pulse_pix)
);

wire [1:0] final_class_pix       = decision_bundle_pix[8:7];
wire [4:0] triggered_sensors_pix = decision_bundle_pix[6:2];
wire [1:0] confidence_pix        = decision_bundle_pix[1:0];

wire ai_busy_pix;
wire weights_ready_pix;
wire weight_load_done_pix;
wire weight_load_error_pix;
wire weight_prefetch_error_pix;
wire cnn_timeout_error_pix;
sync_2ff u_sync_ai_busy        (.dst_clk(pixel_clk), .dst_rst_n(pixel_rst_n),
                                .async_in(ai_busy),               .sync_out(ai_busy_pix));
sync_2ff u_sync_weights_ready  (.dst_clk(pixel_clk), .dst_rst_n(pixel_rst_n),
                                .async_in(weights_ready),         .sync_out(weights_ready_pix));
sync_2ff u_sync_weight_ld_done (.dst_clk(pixel_clk), .dst_rst_n(pixel_rst_n),
                                .async_in(weight_load_done),      .sync_out(weight_load_done_pix));
sync_2ff u_sync_weight_ld_err  (.dst_clk(pixel_clk), .dst_rst_n(pixel_rst_n),
                                .async_in(weight_load_error),     .sync_out(weight_load_error_pix));
sync_2ff u_sync_wp_err         (.dst_clk(pixel_clk), .dst_rst_n(pixel_rst_n),
                                .async_in(weight_prefetch_error), .sync_out(weight_prefetch_error_pix));
sync_2ff u_sync_cnn_to_err     (.dst_clk(pixel_clk), .dst_rst_n(pixel_rst_n),
                                .async_in(cnn_timeout_error),     .sync_out(cnn_timeout_error_pix));

// Vital signs are byte-wide buses written atomically by I2C, but I2C updates
// at ~1 kHz which is millions of pixel_clk cycles apart. Bit-wise sync is
// safe because OSD redraws every frame (60 Hz) and any 1-2 pixel-cycle
// bit-skew is invisible to the eye.
wire [7:0] spo2_raw_pix;
wire [7:0] temp_raw_pix;
genvar gv;
generate
    for (gv = 0; gv < 8; gv = gv + 1) begin : g_sync_vitals
        sync_2ff u_sync_spo2 (.dst_clk(pixel_clk), .dst_rst_n(pixel_rst_n),
                              .async_in(spo2_disp[gv]), .sync_out(spo2_raw_pix[gv]));
        sync_2ff u_sync_temp (.dst_clk(pixel_clk), .dst_rst_n(pixel_rst_n),
                              .async_in(temp_disp[gv]), .sync_out(temp_raw_pix[gv]));
    end
endgenerate

// Augment triggered_sensors with error flags in the PIXEL domain. The OR-mix
// must happen here (not in sys_clk) so the OSD input is purely pixel-domain
// and no sys_clk register fans out to the OSD r/g/b registers anymore.
wire [4:0] triggered_sensors_osd = triggered_sensors_pix |
                                   {2'b00,
                                    weight_load_error_pix | weight_prefetch_error_pix | cnn_timeout_error_pix,
                                    ai_busy_pix,
                                    weight_load_done_pix | weights_ready_pix};

// ---------------------------------------------------------------------------
// Display and debug UART
// ---------------------------------------------------------------------------
wire [11:0] hcount;
wire [11:0] vcount;
wire hs;
wire vs;
wire de;

vga_timing #(
    .H_ACTIVE(1280), .H_FP(110), .H_SYNC(40), .H_BP(220),
    .V_ACTIVE(720),  .V_FP(5),   .V_SYNC(5),  .V_BP(20),
    .HS_POL(1'b1),   .VS_POL(1'b1)
) u_vga (
    .clk     (pixel_clk),
    .rst     (~pixel_rst_n),
    .hs      (hs),
    .vs      (vs),
    .de      (de),
    .active_x(hcount),
    .active_y(vcount)
);

wire [23:0] wave_pixel;

// ── Waveform source: DECOUPLED from the AI core ──────────────────────────────
// Previously the traces were driven by the FIFO READ strobes (eeg_fifo_rd), so
// they only moved while the shared AI core was actively reading a channel -> they
// went blank whenever the AI core was in reset (boot not done / DDR not ready) or
// between channels. Drive them from the WRITE stream (replay or live sensor)
// instead: the monitor traces now always show the acquired signal, all three
// lanes update together, independent of AI/DDR/boot state.
//
// Scaling: waveform_display expects a centered UINT8 [0..255] (128 = mid-lane).
// The raw signed int16 sample's high byte [15:8] barely moves for the small test
// signals (~±200..±550) and rails the beam to the lane edges. Convert signed
// int16 -> centered uint8 with a ÷4 gain (>>>2). Tune the shift if a live sensor
// has a very different amplitude.
wire signed [15:0] eeg_wave_sh = $signed(eeg_wr_data) >>> 2;
wire signed [15:0] ecg_wave_sh = $signed(ecg_wr_data) >>> 2;
wire signed [15:0] emg_wave_sh = $signed(emg_wr_data) >>> 2;
wire [7:0] eeg_wave8 = (eeg_wave_sh > 16'sd127)  ? 8'd255 :
                       (eeg_wave_sh < -16'sd128) ? 8'd0   : (eeg_wave_sh + 16'sd128);
wire [7:0] ecg_wave8 = (ecg_wave_sh > 16'sd127)  ? 8'd255 :
                       (ecg_wave_sh < -16'sd128) ? 8'd0   : (ecg_wave_sh + 16'sd128);
wire [7:0] emg_wave8 = (emg_wave_sh > 16'sd127)  ? 8'd255 :
                       (emg_wave_sh < -16'sd128) ? 8'd0   : (emg_wave_sh + 16'sd128);

waveform_display u_wave (
    .sys_clk    (sys_clk),
    .rst_n      (sys_rst_n),
    .pixel_clk  (pixel_clk),
    .pixel_rst_n(pixel_rst_n),
    .eeg_sample (eeg_wave8),
    .eeg_valid  (eeg_wr_en),
    .ecg_sample (ecg_wave8),
    .ecg_valid  (ecg_wr_en),
    .emg_sample (emg_wave8),
    .emg_valid  (emg_wr_en),
    .hcount     (hcount),
    .vcount     (vcount),
    .de         (de),
    .pixel_out  (wave_pixel)
);

wire [7:0] r_osd;
wire [7:0] g_osd;
wire [7:0] b_osd;

osd_overlay u_osd (
    .pixel_clk        (pixel_clk),
    .rst_n            (pixel_rst_n),
    .hcount           (hcount),
    .vcount           (vcount),
    .de               (de),
    // All inputs below are pixel_clk-domain (see Phase 5d CDC block above).
    .class_out        (final_class_pix),
    .triggered_sensors(triggered_sensors_osd),
    .confidence       (confidence_pix),
    .spo2_raw         (spo2_raw_pix),
    .temp_raw         (temp_raw_pix),
    .wave_pixel       (wave_pixel),
    .r_out            (r_osd),
    .g_out            (g_osd),
    .b_out            (b_osd)
);

// ---------------------------------------------------------------------------
// HDMI sync alignment to the OSD pixel pipeline.
// The OSD (waveform_display -> osd_overlay) emits r/g/b OSD_PIPE_LATENCY pixel
// clocks after the (hcount,vcount,de) it was computed from. Delay hs/vs/de by
// the same amount so the active region and blanking edges stay pixel-perfect at
// the DVI transmitter. KEEP this equal to osd_overlay's OSD_LATENCY localparam.
localparam OSD_PIPE_LATENCY = 5;
reg [OSD_PIPE_LATENCY-1:0] hs_pipe, vs_pipe, de_pipe;
always @(posedge pixel_clk or negedge pixel_rst_n) begin
    if (!pixel_rst_n) begin
        hs_pipe <= {OSD_PIPE_LATENCY{1'b0}};
        vs_pipe <= {OSD_PIPE_LATENCY{1'b0}};
        de_pipe <= {OSD_PIPE_LATENCY{1'b0}};
    end else begin
        hs_pipe <= {hs_pipe[OSD_PIPE_LATENCY-2:0], hs};
        vs_pipe <= {vs_pipe[OSD_PIPE_LATENCY-2:0], vs};
        de_pipe <= {de_pipe[OSD_PIPE_LATENCY-2:0], de};
    end
end
wire hs_dvi = hs_pipe[OSD_PIPE_LATENCY-1];
wire vs_dvi = vs_pipe[OSD_PIPE_LATENCY-1];
wire de_dvi = de_pipe[OSD_PIPE_LATENCY-1];

reg [23:0] debug_counter;
always @(posedge sys_clk or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
        debug_counter <= 24'd0;
        tx_data_r     <= 8'd0;
        tx_valid_r    <= 1'b0;
    end else begin
        tx_valid_r    <= 1'b0;
        debug_counter <= debug_counter + 1'b1;
        if (tx_ready_w && debug_counter == 24'd0) begin
            tx_data_r  <= {active_channel, final_class, confidence, ai_error_any, ai_busy};
            tx_valid_r <= 1'b1;
        end
    end
end

DVI_TX_Top dvi_tx_i (
    .I_rst_n      (pixel_rst_n),
    .I_serial_clk (serial_clk),
    .I_rgb_clk    (pixel_clk),
    .I_rgb_vs     (vs_dvi),
    .I_rgb_hs     (hs_dvi),
    .I_rgb_de     (de_dvi),
    .I_rgb_r      (r_osd),
    .I_rgb_g      (g_osd),
    .I_rgb_b      (b_osd),
    .O_tmds_clk_p (tmds_clk_p_0),
    .O_tmds_clk_n (tmds_clk_n_0),
    .O_tmds_data_p(tmds_d_p_0),
    .O_tmds_data_n(tmds_d_n_0)
);

endmodule

// ---------------------------------------------------------------------------
// replay_rom - DEPTH x 16 single-port ROM with a one-cycle registered read.
// INIT_FILE is a BARE filename loaded with $readmemh (one 4-char hex value per
// line). GowinSynthesis resolves it relative to THIS .v's source dir (rtl/top/),
// so extract_sample.py writes test_{eeg,ecg,emg}.hex into rtl/top/. (Sim resolves
// relative to the run cwd, where the test harness copies the file.)
// syn_ramstyle="block_ram" forces BSRAM inference.
// ---------------------------------------------------------------------------
module replay_rom #(
    parameter INIT_FILE = "",
    parameter AW        = 11,
    parameter DEPTH     = 2048
)(
    input              clk,
    input  [AW-1:0]    addr,
    output reg [15:0]  dout
);
    (* syn_ramstyle = "block_ram" *) reg [15:0] mem [0:DEPTH-1];
    initial begin
        if (INIT_FILE != "")
            $readmemh(INIT_FILE, mem);
    end
    always @(posedge clk)
        dout <= mem[addr];
endmodule

// ---------------------------------------------------------------------------
// weight_image_rom - byte-wide ROM containing the packed biomedical weight
// image generated by tools/pack_weight_image.py. The top-level boot FSM streams
// this ROM through weight_boot_loader, preserving the manifest CRC validation
// before DDR3-backed inference is released.
//
// Read is REGISTERED (1-cycle latency). Gowin GW5A BSRAM only supports a
// registered read port, so an asynchronous `assign dout = mem[addr]` together
// with syn_ramstyle="block_ram" is contradictory and forces the 32 Kbit image
// into LUT-based distributed ROM (large, and CLS utilisation is already ~79%).
// The boot FSM compensates for the extra cycle with a one-cycle `pending` bubble
// per byte; the manifest CRC check inside weight_boot_loader is the alignment
// oracle (any off-by-one in the stream fails CRC -> weight_load_error).
// ---------------------------------------------------------------------------
module weight_image_rom #(
    parameter INIT_FILE = "",
    parameter AW        = 12,
    parameter DEPTH     = 4096
)(
    input              clk,
    input      [AW-1:0] addr,
    output reg [7:0]   dout
);
    (* syn_ramstyle = "block_ram" *) reg [7:0] mem [0:DEPTH-1];
    initial begin
        if (INIT_FILE != "")
            $readmemh(INIT_FILE, mem);
    end
    always @(posedge clk)
        dout <= mem[addr];
endmodule
