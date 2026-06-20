// top_shared_ai.v - Top Tang Mega cho kiến trúc AI dùng chung dựa trên DDR3.
//
// Mục tiêu này giữ một làn STFT/CNN và ghép kênh theo thời gian EEG/ECG/EMG. Trọng số
// CNN được nạp từ DDR3 vào một cache cục bộ nhỏ trước mỗi kênh.
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
// Thu nhận tín hiệu cảm biến và các FIFO theo từng kênh
// ---------------------------------------------------------------------------
wire [15:0] emg_sample_uart;
wire        emg_valid_uart;
reg  [7:0]  tx_data_r;
reg         tx_valid_r;
wire        tx_ready_w;

uart_top #(
    .CLK_FRE  (50),          // phải khớp sys_clk từ gowin_pll_sys (50 MHz)
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
// Phát lại tín hiệu đa kênh (Tự kiểm tra - Self-Test)
// ---------------------------------------------------------------------------
// Nhấn AB13 (case_next_n, tích cực mức thấp có điện trở kéo lên) phát lại một
// cửa sổ kiểm thử đã lưu cho mỗi kênh (EEG/ECG/EMG) cộng với chỉ số sinh tồn
// SpO2/Temp mô phỏng. Các mẫu phát lại được MUX vào chính các FIFO theo từng kênh
// mà cảm biến thực cấp vào, nên pipeline STFT/CNN/quyết định phía sau được chạy đầu-cuối.

// --- Khử rung nút nhấn (debounce) -> replay_trigger 1 chu kỳ ---
reg  [1:0]  btn_sync;
reg  [15:0] btn_cnt;
reg         btn_stable;     // mức đã khử rung (1 = nhả nút)
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
wire replay_trigger = btn_stable_d & ~btn_stable;   // cạnh xuống = một lần nhấn mới

// --- Nhấn AB13 luân chuyển case phát lại: live -> case1 -> case2 -> ... -> live ---
// Mỗi lần nhấn sạch sẽ tăng replay_case. 0 = cảm biến thực (tắt phát lại); 1..N chạy
// một kịch bản lâm sàng đã lưu (một cửa sổ mỗi kênh + chỉ số sinh tồn mô phỏng) dẫn tới
// một quyết định riêng biệt (Bình thường / Bất thường / Nguy kịch). Nhấn quá case cuối
// quay về live. mode_replay đơn giản là "đang chọn một case phát lại".
localparam integer N_REPLAY_CASES  = 3;                       // kịch bản demo (không tính live)
localparam integer REPLAY_ROM_DEPTH = N_REPLAY_CASES * SAMPLE_FIFO_DEPTH;  // 3 x 2048
localparam integer REPLAY_ROM_AW    = 13;                     // ceil(log2(6144))
reg [1:0] replay_case;   // 0 = live, 1..N_REPLAY_CASES = kịch bản
always @(posedge sys_clk or negedge sys_rst_n) begin
    if (!sys_rst_n)          replay_case <= 2'd0;
    else if (replay_trigger) replay_case <= (replay_case == N_REPLAY_CASES[1:0]) ? 2'd0
                                                                                  : replay_case + 2'd1;
end
wire mode_replay = (replay_case != 2'd0);
// Gốc cửa sổ trong mỗi ROM theo từng kênh = (case-1) * 2048; live -> cửa sổ 0 (không dùng).
wire [1:0] rep_win = mode_replay ? (replay_case - 2'd1) : 2'd0;

// --- Con trỏ đọc phát lại lặp vòng + FSM ---
localparam [SAMPLE_FIFO_AW-1:0] REP_LAST = SAMPLE_FIFO_DEPTH - 1;
localparam [1:0]  R_IDLE = 2'd0, R_ADDR = 2'd1, R_WRITE = 2'd2;
reg  [1:0]  rep_state;
reg  [SAMPLE_FIFO_AW-1:0] rep_addr;
reg         rep_we;               // xung ghi 1 chu kỳ dùng chung cho cả 3 FIFO
reg         vitals_updated_rep;   // một xung duy nhất khi vào chế độ phát lại

// Chặn ngược (backpressure): chỉ tiến/ghi khi mọi FIFO đích còn chỗ. Với
// FIFO sâu 2048 thì một khung đầy đủ theo từng kênh vừa khít, nên lõi AI ghép kênh
// theo thời gian có thể rút từng kênh một mà bên ghi không bị bế tắc.
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
                    vitals_updated_rep <= 1'b1;   // chốt chỉ số sinh tồn mô phỏng một lần
                    rep_state          <= R_ADDR;
                end
            end
            // Đưa rep_addr ra; kết quả đọc ROM có thanh ghi về sau một chu kỳ.
            R_ADDR: rep_state <= mode_replay ? R_WRITE : R_IDLE;
            // Dữ liệu ROM cho rep_addr đã hợp lệ; ghi một mẫu mỗi kênh rồi
            // tiến tới, vòng 2047->0 để mẫu lặp lại khi chế độ vẫn bật.
            R_WRITE: begin
                if (!mode_replay) begin
                    rep_state <= R_IDLE;
                end else if (rep_fifo_ready) begin
                    rep_we    <= 1'b1;
                    rep_addr  <= (rep_addr == REP_LAST) ? {SAMPLE_FIFO_AW{1'b0}} : rep_addr + 1'b1;
                    rep_state <= R_ADDR;
                end
                // ngược lại thì giữ (rep_addr đóng băng -> dữ liệu ROM vẫn hợp lệ)
            end
            default: rep_state <= R_IDLE;
        endcase
    end
end

// --- Các ROM mẫu phát lại (N_REPLAY_CASES x 2048 x 16, đọc có thanh ghi) ---
// Mỗi file hex theo từng kênh (extract_sample.py) là N cửa sổ case nối tiếp theo
// thứ tự case. Cửa sổ đang hoạt động = {rep_win, rep_addr} (gốc cửa sổ + chỉ số mẫu).
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

// --- Xung ghi từ cảm biến thực ---
wire eeg_wr_sensor = spi_valid_raw && (spi_channel_raw == 2'd0);
wire ecg_wr_sensor = spi_valid_raw && (spi_channel_raw == 2'd1);
wire emg_wr_sensor = emg_valid_uart;

// --- MUX ghi FIFO: đường phát lại khi mode_replay, cảm biến thực nếu ngược lại ---
wire        eeg_wr_en   = mode_replay ? rep_we       : eeg_wr_sensor;
wire        ecg_wr_en   = mode_replay ? rep_we       : ecg_wr_sensor;
wire        emg_wr_en   = mode_replay ? rep_we       : emg_wr_sensor;
wire [15:0] eeg_wr_data = mode_replay ? rep_eeg_data : spi_sample_raw;
wire [15:0] ecg_wr_data = mode_replay ? rep_ecg_data : spi_sample_raw;
wire [15:0] emg_wr_data = mode_replay ? rep_emg_data : emg_sample_uart;

// --- Chỉ số sinh tồn mô phỏng theo từng case (giữ khi case đó được chọn) ---
// Được chọn để củng cố mức quyết định của mỗi kịch bản (temp là 0.5C/LSB: 72=36.0C,
// 80=40.0C). Giữ đồng bộ với CASES trong software/datasets/extract_sample.py.
reg [7:0] rep_spo2, rep_temp;
always @(*) begin
    case (replay_case)
        2'd1:    begin rep_spo2 = 8'd98; rep_temp = 8'd72; end  // Bình thường (97%, 36.0C)
        2'd2:    begin rep_spo2 = 8'd92; rep_temp = 8'd72; end  // Bất thường  (92%, 36.0C)
        2'd3:    begin rep_spo2 = 8'd88; rep_temp = 8'd80; end  // Nguy kịch   (88%, 40.0C)
        default: begin rep_spo2 = 8'd98; rep_temp = 8'd72; end
    endcase
end

// --- MUX chỉ số sinh tồn: giá trị mô phỏng theo case khi phát lại, I2C thực nếu ngược lại ---
wire [7:0]  spo2_disp      = mode_replay ? rep_spo2 : spo2_raw;
wire [7:0]  temp_disp      = mode_replay ? rep_temp : temp_raw;
wire        vitals_upd_mux = mode_replay ? vitals_updated_rep : vitals_updated;

sync_fifo #(.DEPTH(SAMPLE_FIFO_DEPTH), .AW(SAMPLE_FIFO_AW)) u_fifo_eeg (
    .Reset(~sys_rst_n),
    .clk  (sys_clk),
    .WrEn(eeg_wr_en),
    .RdEn(eeg_fifo_rd),
    .Data(eeg_wr_data),
    .Q(eeg_sample),
    .Empty(eeg_fifo_empty),
    .Full(eeg_fifo_full)
);

sync_fifo #(.DEPTH(SAMPLE_FIFO_DEPTH), .AW(SAMPLE_FIFO_AW)) u_fifo_ecg (
    .Reset(~sys_rst_n),
    .clk  (sys_clk),
    .WrEn(ecg_wr_en),
    .RdEn(ecg_fifo_rd),
    .Data(ecg_wr_data),
    .Q(ecg_sample),
    .Empty(ecg_fifo_empty),
    .Full(ecg_fifo_full)
);

sync_fifo #(.DEPTH(SAMPLE_FIFO_DEPTH), .AW(SAMPLE_FIFO_AW)) u_fifo_emg (
    .Reset(~sys_rst_n),
    .clk  (sys_clk),
    .WrEn(emg_wr_en),
    .RdEn(emg_fifo_rd),
    .Data(emg_wr_data),
    .Q(emg_sample),
    .Empty(emg_fifo_empty),
    .Full(emg_fifo_full)
);

// ---------------------------------------------------------------------------
// Cổng native DDR3
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
// Bộ nạp trọng số Flash/ROM -> DDR3 lúc khởi động
// ---------------------------------------------------------------------------
// Trình tự: RESET -> LOAD_WEIGHTS -> WAIT_CALIB -> RUN. LOAD_WEIGHTS chờ
// DDR3 hiệu chỉnh (calibration) xong trước khi khởi động weight_boot_loader có kiểm CRC, vì
// cổng ghi native DDR3 không được phép dùng trước init_calib_complete.
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
reg       weight_flash_pending;   // đã đưa addr, chờ 1 chu kỳ cho ROM có thanh ghi
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

// Phương án dự phòng tự kiểm tra: khi mode_replay bật, vẫn nhả lõi AI / trao cho nó
// cổng DDR ngay cả khi quá trình boot trọng số chưa bao giờ tới BOOT_RUN (vd: DDR3
// không hiệu chỉnh được trên bo). Điều này giữ demo phát lại còn sống (pipeline chạy; nếu DDR
// hỏng thì prefetch chỉ hết giờ (timeout) theo từng kênh). mode_replay chỉ bật/tắt rất lâu
// sau khi boot xong (khử rung ~64Ki chu kỳ + thao tác người), nên không có tranh chấp
// cổng-DDR boot-với-AI thực sự. Trọng số CNN có thể là rác trong phương án dự phòng này.
wire run_enable_eff      = boot_run_enable | mode_replay;
wire ddr_boot_owns_port  = !run_enable_eff;

// INIT_FILE là tên file TRƠ (không đường dẫn). GowinSynthesis phân giải $readmemh tên-trơ
// tương đối với thư mục NGUỒN .v (file này -> rtl/top/), giống hệt như
// font8x16.hex phân giải cạnh text_renderer.v trong rtl/display/. Nó KHÔNG
// tìm trong Final/ hay thư mục làm việc của tổng hợp. Nếu thiếu file ở đó thì khởi tạo ROM
// thất bại (EX3988) và toàn bộ ROM bị quét bỏ (NL0002) -> trên bo, bộ
// nạp truyền toàn số 0 và CRC thất bại. Vì vậy giữ biomed_weights.hex trong rtl/top/
// (được sinh/sao chép vào đó) VÀ một bản trong verification/ cho cwd của sim cocotb.
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
                // Truyền ROM có thanh ghi vào bộ nạp. Vì việc đọc ROM
                // có thanh ghi (độ trễ 1 chu kỳ), mỗi địa chỉ mới cần một
                // bong bóng `pending` một chu kỳ trước khi byte của nó hợp lệ; trong lúc
                // bộ nạp chặn ngược thì địa chỉ được giữ để đầu ra ROM (và
                // do đó flash_data) ổn định.
                if (ddr_init_calib_complete) begin
                    if (!weight_boot_started) begin
                        weight_boot_started  <= 1'b1;
                        weight_boot_start_r  <= 1'b1;
                        weight_flash_addr    <= {WEIGHT_IMAGE_AW{1'b0}};
                        weight_flash_pending <= 1'b1;   // dữ liệu ROM cho addr 0 về ở chu kỳ kế
                        weight_flash_valid_r <= 1'b0;
                    end else if (weight_flash_pending) begin
                        weight_flash_pending <= 1'b0;
                        weight_flash_valid_r <= 1'b1;   // đầu ra ROM có thanh ghi nay đã hợp lệ
                    end else if (weight_flash_valid_r && weight_flash_ready) begin
                        if (weight_flash_addr == WEIGHT_IMAGE_LAST) begin
                            weight_flash_valid_r <= 1'b0;
                        end else begin
                            weight_flash_addr    <= weight_flash_addr + 1'b1;
                            weight_flash_valid_r <= 1'b0;
                            weight_flash_pending <= 1'b1;   // chờ byte ROM kế tiếp
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
// Lõi AI dùng chung và các ROM
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
// Pha 5d: Vượt miền clock từ AI (sys_clk) -> Hiển thị (pixel_clk)
// ---------------------------------------------------------------------------
// Lớp phủ OSD chạy ở pixel_clk. Tất cả tín hiệu trạng thái AI đến từ sys_clk.
// Cầu nối trực tiếp vào đầu vào u_osd tạo ra một phân tích cùng-tên-clock
// (trường hợp tệ nhất dưới ràng buộc sys_clk) với các đường fan-out sâu
// `state[*] -> đầu ra r/g/b của OSD`. Pha 5d chèn các bộ đồng bộ đúng cách để
// mọi tín hiệu tới u_osd đều đã ở miền pixel_clk.
//
// Loại bus       | Khối CDC            | Đảm bảo tính nguyên tử
// ---------------|---------------------|---------------------
// Gói quyết định | cdc_bus_handshake   | CÓ — gói được chốt khi src_update,
//   (9 bit)      |                     |   đích lấy mẫu ở cạnh toggle
// Cờ trạng thái  | sync_2ff (mỗi bit)  | các bit độc lập; sự không nhất quán
//   (1 bit mỗi cờ)|                    |   nhất thời giữa các cờ là chấp nhận được
// Chỉ số sinh tồn| sync_2ff (mỗi bit)  | I2C cập nhật cả byte mỗi lần ghi
//   (8 bit mỗi cái)|                   |   nhưng hiển thị theo nhịp điểm ảnh ở thang ms
//                 |                     |   nên lệch bit ngắn là không nhìn thấy

wire [8:0] decision_bundle_src = {final_class, triggered_sensors, confidence};
wire [8:0] decision_bundle_pix;
wire       decision_pulse_pix;   // không dùng nhưng giữ lại phòng khi OSD muốn nhấp nháy

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

// Chỉ số sinh tồn là các bus rộng byte được I2C ghi nguyên tử, nhưng I2C cập nhật
// ở ~1 kHz, tức cách nhau hàng triệu chu kỳ pixel_clk. Đồng bộ theo từng bit là
// an toàn vì OSD vẽ lại mỗi khung (60 Hz) và bất kỳ lệch bit 1-2 chu kỳ điểm ảnh
// nào cũng không nhìn thấy bằng mắt.
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

// Bổ sung các cờ lỗi vào triggered_sensors trong miền PIXEL. Phép trộn-OR
// phải diễn ra ở đây (không phải ở sys_clk) để đầu vào OSD thuần miền pixel
// và không còn thanh ghi sys_clk nào fan-out tới các thanh ghi r/g/b của OSD.
wire [4:0] triggered_sensors_osd = triggered_sensors_pix |
                                   {2'b00,
                                    weight_load_error_pix | weight_prefetch_error_pix | cnn_timeout_error_pix,
                                    ai_busy_pix,
                                    weight_load_done_pix | weights_ready_pix};

// ---------------------------------------------------------------------------
// Hiển thị và UART gỡ lỗi
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

// ── Nguồn dạng sóng: TÁCH RỜI khỏi lõi AI ────────────────────────────────────
// Trước đây các vệt sóng được điều khiển bởi xung ĐỌC FIFO (eeg_fifo_rd), nên
// chúng chỉ chuyển động khi lõi AI dùng chung đang đọc một kênh -> chúng
// tắt trắng bất cứ khi nào lõi AI ở trạng thái reset (chưa boot xong / DDR chưa sẵn sàng) hoặc
// giữa các kênh. Thay vào đó điều khiển chúng từ luồng GHI (phát lại hoặc cảm biến thực):
// các vệt theo dõi nay luôn hiển thị tín hiệu thu được, cả ba
// làn cùng cập nhật, độc lập với trạng thái AI/DDR/boot.
//
// Tỉ lệ: waveform_display kỳ vọng UINT8 căn giữa [0..255] (128 = giữa làn).
// Byte cao [15:8] của mẫu int16 có dấu thô gần như không nhúc nhích với các tín hiệu
// kiểm thử nhỏ (~±200..±550) và đẩy tia ra mép làn. Chuyển int16 có dấu
// -> uint8 căn giữa với hệ số ÷4 (>>>2). Chỉnh lượng dịch nếu một cảm biến thực
// có biên độ rất khác.
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
    // Tất cả đầu vào bên dưới đều thuộc miền pixel_clk (xem khối CDC Pha 5d ở trên).
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
// Căn chỉnh đồng bộ HDMI với pipeline điểm ảnh của OSD.
// OSD (waveform_display -> osd_overlay) phát r/g/b sau OSD_PIPE_LATENCY chu kỳ
// pixel_clk so với (hcount,vcount,de) mà nó được tính từ đó. Làm trễ hs/vs/de
// cùng lượng đó để vùng tích cực và các cạnh blanking khớp chính xác từng điểm ảnh tại
// bộ phát DVI. GIỮ giá trị này bằng localparam OSD_LATENCY của osd_overlay.
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
// replay_rom - ROM đơn cổng DEPTH x 16 với đọc có thanh ghi một chu kỳ.
// INIT_FILE là tên file TRƠ được nạp bằng $readmemh (một giá trị hex 4 ký tự mỗi
// dòng). GowinSynthesis phân giải nó tương đối với thư mục nguồn của CHÍNH file .v này (rtl/top/),
// nên extract_sample.py ghi test_{eeg,ecg,emg}.hex vào rtl/top/. (Sim phân giải
// tương đối với cwd lúc chạy, nơi test harness sao chép file vào.)
// syn_ramstyle="block_ram" ép suy luận thành BSRAM.
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
// weight_image_rom - ROM rộng byte chứa ảnh trọng số y sinh đã đóng gói
// do software/pack_weight_image.py sinh ra. FSM boot mức trên cùng truyền
// ROM này qua weight_boot_loader, giữ nguyên việc kiểm tra CRC trong manifest
// trước khi nhả suy luận dựa trên DDR3.
//
// Đọc CÓ THANH GHI (độ trễ 1 chu kỳ). BSRAM của Gowin GW5A chỉ hỗ trợ một
// cổng đọc có thanh ghi, nên `assign dout = mem[addr]` bất đồng bộ cùng
// với syn_ramstyle="block_ram" là mâu thuẫn và ép ảnh 32 Kbit
// vào ROM phân tán dựa trên LUT (lớn, và mức dùng CLS đã ~79%).
// FSM boot bù cho chu kỳ thừa bằng một bong bóng `pending` một chu kỳ
// mỗi byte; phép kiểm CRC trong manifest bên trong weight_boot_loader là bộ
// xác nhận căn chỉnh (bất kỳ lệch một-bước nào trong luồng đều làm CRC thất bại -> weight_load_error).
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
