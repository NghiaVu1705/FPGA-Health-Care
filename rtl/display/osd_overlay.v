// osd_overlay.v — OSD màn hình theo dõi y tế cho hiển thị 1280×720
//
// Bố cục:
//   hàng   0..599 : 3 làn dạng sóng (EEG/ECG/EMG), từ waveform_display.
//   hàng 600..655 : dải trạng thái -> [STATUS: x] [CONF: x] [AI READY]
//   hàng 656..719 : các thẻ cảm biến/chỉ số sinh tồn
//                   [EEG OK/TRIG][ECG ..][EMG ..][SPO2 nn%][TEMP nn.n C]
//
// Định thời: bộ tổng hợp (compositor) theo lớp, pipeline hoàn toàn (không có
// framebuffer). Chuỗi sâu hcount -> chọn-ký-tự -> ROM-font -> điểm ảnh được chia
// thành các tầng ngắn (xem ROM font BSRAM của text_renderer). Tra bảng màu cuối
// cùng có thanh ghi. Độ trễ OSD_LATENCY điểm ảnh; tín hiệu đồng bộ HDMI
// (hs/vs/de) bị làm trễ cùng một lượng trong top_shared_ai.
module osd_overlay (
    input  pixel_clk,
    input  rst_n,

    // Vị trí VGA
    input  [11:0] hcount,
    input  [11:0] vcount,
    input         de,

    // Dữ liệu sức khỏe (từ decision_layer + threshold_proc)
    input  [1:0] class_out,           // 0=Bình thường, 1=Bất thường, 2=Nguy kịch
    input  [4:0] triggered_sensors,   // {EEG[4], ECG[3], EMG[2], SpO₂[1], Temp[0]}
    input  [1:0] confidence,          // 0=THẤP, 1=TRUNG BÌNH, 2=CAO
    input  [7:0] spo2_raw,            // UINT8 [0..100]
    input  [7:0] temp_raw,            // UINT8 0.5°C/LSB

    // Đầu vào điểm ảnh dạng sóng (chuyển thẳng từ waveform_display)
    input  [23:0] wave_pixel,

    // Điểm ảnh đầu ra
    output reg [7:0] r_out,
    output reg [7:0] g_out,
    output reg [7:0] b_out
);

// ── Bảng màu ──────────────────────────────────────────────────────────────────
localparam [23:0]
    COLOR_NORMAL   = 24'h00CC44,   // xanh lá
    COLOR_ABNORMAL = 24'hFFAA00,   // hổ phách (vàng cam)
    COLOR_CRITICAL = 24'hFF2222,   // đỏ
    COLOR_WHITE    = 24'hFFFFFF,
    COLOR_GRAY     = 24'h444444,
    COLOR_BLACK    = 24'h000000,
    COLOR_ACTIVE   = 24'h00AAFF,   // xanh dương cho cảm biến đang hoạt động
    COLOR_DARK     = 24'h101820,   // nền của panel
    COLOR_FRAME    = 24'h0088CC,   // viền panel màu lục lam
    COLOR_TEXT_BG  = 24'hF8F8F8,
    COLOR_WAVE_BG  = 24'h111111,
    COLOR_WAVE_GRID= 24'h222222,
    COLOR_EEG      = 24'h00FF88,
    COLOR_ECG      = 24'hFF4444,
    COLOR_EMG      = 24'h4488FF;

localparam [4:0]
    IDX_BLACK    = 5'd0,
    IDX_NORMAL   = 5'd1,
    IDX_ABNORMAL = 5'd2,
    IDX_CRITICAL = 5'd3,
    IDX_WHITE    = 5'd4,
    IDX_GRAY     = 5'd5,
    IDX_ACTIVE   = 5'd6,
    IDX_DARK     = 5'd7,
    IDX_FRAME    = 5'd8,
    IDX_TEXT_BG  = 5'd9,
    IDX_WAVE_BG  = 5'd10,
    IDX_WAVE_GRID= 5'd11,
    IDX_EEG      = 5'd12,
    IDX_ECG      = 5'd13,
    IDX_EMG      = 5'd14;

function [23:0] palette_rgb;
    input [4:0] idx;
    begin
        case (idx)
            IDX_NORMAL:    palette_rgb = COLOR_NORMAL;
            IDX_ABNORMAL:  palette_rgb = COLOR_ABNORMAL;
            IDX_CRITICAL:  palette_rgb = COLOR_CRITICAL;
            IDX_WHITE:     palette_rgb = COLOR_WHITE;
            IDX_GRAY:      palette_rgb = COLOR_GRAY;
            IDX_ACTIVE:    palette_rgb = COLOR_ACTIVE;
            IDX_DARK:      palette_rgb = COLOR_DARK;
            IDX_FRAME:     palette_rgb = COLOR_FRAME;
            IDX_TEXT_BG:   palette_rgb = COLOR_TEXT_BG;
            IDX_WAVE_BG:   palette_rgb = COLOR_WAVE_BG;
            IDX_WAVE_GRID: palette_rgb = COLOR_WAVE_GRID;
            IDX_EEG:       palette_rgb = COLOR_EEG;
            IDX_ECG:       palette_rgb = COLOR_ECG;
            IDX_EMG:       palette_rgb = COLOR_EMG;
            default:       palette_rgb = COLOR_BLACK;
        endcase
    end
endfunction

function [4:0] wave_rgb_to_idx;
    input [23:0] rgb;
    begin
        case (rgb)
            COLOR_EEG:       wave_rgb_to_idx = IDX_EEG;
            COLOR_ECG:       wave_rgb_to_idx = IDX_ECG;
            COLOR_EMG:       wave_rgb_to_idx = IDX_EMG;
            COLOR_WAVE_GRID: wave_rgb_to_idx = IDX_WAVE_GRID;
            COLOR_WAVE_BG:   wave_rgb_to_idx = IDX_WAVE_BG;
            default:         wave_rgb_to_idx = IDX_WAVE_BG;
        endcase
    end
endfunction

(* syn_ramstyle = "block_ram" *) reg [23:0] clut_rom [0:31];
integer clut_i;
initial begin
    for (clut_i = 0; clut_i < 32; clut_i = clut_i + 1)
        clut_rom[clut_i] = COLOR_BLACK;
    clut_rom[IDX_NORMAL]    = COLOR_NORMAL;
    clut_rom[IDX_ABNORMAL]  = COLOR_ABNORMAL;
    clut_rom[IDX_CRITICAL]  = COLOR_CRITICAL;
    clut_rom[IDX_WHITE]     = COLOR_WHITE;
    clut_rom[IDX_GRAY]      = COLOR_GRAY;
    clut_rom[IDX_ACTIVE]    = COLOR_ACTIVE;
    clut_rom[IDX_DARK]      = COLOR_DARK;
    clut_rom[IDX_FRAME]     = COLOR_FRAME;
    clut_rom[IDX_TEXT_BG]   = COLOR_TEXT_BG;
    clut_rom[IDX_WAVE_BG]   = COLOR_WAVE_BG;
    clut_rom[IDX_WAVE_GRID] = COLOR_WAVE_GRID;
    clut_rom[IDX_EEG]       = COLOR_EEG;
    clut_rom[IDX_ECG]       = COLOR_ECG;
    clut_rom[IDX_EMG]       = COLOR_EMG;
end

// ── Hằng số bố cục ────────────────────────────────────────────────────────────
localparam [11:0] OSD_TOP       = 12'd600;   // thanh HUD bắt đầu ở hàng 600
localparam [11:0] BANNER_BOT    = 12'd656;   // dải banner = hàng 600..655
localparam [11:0] TEXT_Y_BANNER = 12'd612;   // chữ 16x32 (2x) căn giữa trong 600..655
localparam [11:0] TEXT_Y_CARDS  = 12'd680;   // chữ 8x16 (1x) căn giữa trong dải thẻ
localparam [11:0] TEXT_Y_EEG    = 12'd8;     // unused — waveform labels removed Phase 3
localparam [11:0] TEXT_Y_ECG    = 12'd208;   // unused
localparam [11:0] TEXT_Y_EMG    = 12'd408;   // unused

// Độ sâu pixel-pipeline từ (hcount,vcount,de) tới (r,g,b). top_shared_ai làm trễ
// tín hiệu đồng bộ HDMI (hs/vs/de) cùng lượng này; giữ hai bên đồng bộ với nhau.
localparam integer OSD_LATENCY = 5;

// ── Trạng thái dẫn xuất ───────────────────────────────────────────────────────
wire [4:0] class_idx = (class_out == 2'd2) ? IDX_CRITICAL :
                       (class_out == 2'd1) ? IDX_ABNORMAL : IDX_NORMAL;
wire [4:0] conf_idx  = (confidence == 2'd2) ? IDX_NORMAL :
                       (confidence == 2'd1) ? IDX_ABNORMAL : IDX_GRAY;

wire eeg_trig  = triggered_sensors[4];
wire ecg_trig  = triggered_sensors[3];
wire emg_trig  = triggered_sensors[2];
wire spo2_trig = triggered_sensors[1];
wire temp_trig = triggered_sensors[0];

wire spo2_low = (spo2_raw < 8'd95);
wire temp_err = (temp_raw < 8'd72) || (temp_raw > 8'd75);

wire [8:0]  char_col   = hcount[11:3];   // 1x: 1280/8 = 160 cột (thẻ)
wire [11:0] char_x     = {char_col, 3'b000};
wire [7:0]  char_col_b = hcount[11:4];   // 2x: 1280/16 = 80 cột (banner)
wire [11:0] char_x_b   = {char_col_b, 4'b0000};

// ── Giải mã vùng ──────────────────────────────────────────────────────────────
wire in_osd    = (vcount >= OSD_TOP) && de;
wire in_banner = in_osd && (vcount <  BANNER_BOT);
wire in_cards  = in_osd && (vcount >= BANNER_BOT);

wire in_banner_text = in_banner && (vcount >= TEXT_Y_BANNER) && (vcount < TEXT_Y_BANNER + 12'd32);
wire in_cards_text  = in_cards  && (vcount >= TEXT_Y_CARDS)  && (vcount < TEXT_Y_CARDS  + 12'd16);

// Khung panel (viền y tế): biên trên, vạch phân tách banner/thẻ, các vách ngăn.
wire on_top_border = in_osd    && (vcount < OSD_TOP + 12'd2);
wire on_band_sep   = in_osd    && (vcount >= BANNER_BOT - 12'd2) && (vcount < BANNER_BOT);
wire on_banner_div = in_banner && ( (hcount >= 12'd400  && hcount < 12'd402)  ||
                                    (hcount >= 12'd800  && hcount < 12'd802) );
wire on_cards_div  = in_cards  && (hcount >= 12'd1024 && hcount < 12'd1026);
wire hud_frame = on_top_border || on_band_sep || on_banner_div || on_cards_div;

// ── Hàm trợ giúp ASCII ────────────────────────────────────────────────────────
function [7:0] digit_tens_0_99;
    input [7:0] value;
    begin
        if      (value >= 8'd90) digit_tens_0_99 = "9";
        else if (value >= 8'd80) digit_tens_0_99 = "8";
        else if (value >= 8'd70) digit_tens_0_99 = "7";
        else if (value >= 8'd60) digit_tens_0_99 = "6";
        else if (value >= 8'd50) digit_tens_0_99 = "5";
        else if (value >= 8'd40) digit_tens_0_99 = "4";
        else if (value >= 8'd30) digit_tens_0_99 = "3";
        else if (value >= 8'd20) digit_tens_0_99 = "2";
        else if (value >= 8'd10) digit_tens_0_99 = "1";
        else                     digit_tens_0_99 = "0";
    end
endfunction

function [7:0] digit_ones_0_99;
    input [7:0] value;
    reg [7:0] rem;
    begin
        if      (value >= 8'd90) rem = value - 8'd90;
        else if (value >= 8'd80) rem = value - 8'd80;
        else if (value >= 8'd70) rem = value - 8'd70;
        else if (value >= 8'd60) rem = value - 8'd60;
        else if (value >= 8'd50) rem = value - 8'd50;
        else if (value >= 8'd40) rem = value - 8'd40;
        else if (value >= 8'd30) rem = value - 8'd30;
        else if (value >= 8'd20) rem = value - 8'd20;
        else if (value >= 8'd10) rem = value - 8'd10;
        else                     rem = value;
        digit_ones_0_99 = 8'h30 + rem[3:0];
    end
endfunction

function [7:0] status_char;
    input [4:0] idx;
    input [1:0] cls;
    begin
        case (idx)
            5'd0: status_char = "S";
            5'd1: status_char = "T";
            5'd2: status_char = "A";
            5'd3: status_char = "T";
            5'd4: status_char = "U";
            5'd5: status_char = "S";
            5'd6: status_char = ":";
            5'd7: status_char = " ";
            5'd8:  status_char = (cls == 2'd2) ? "C" : (cls == 2'd1) ? "A" : "N";
            5'd9:  status_char = (cls == 2'd2) ? "R" : (cls == 2'd1) ? "B" : "O";
            5'd10: status_char = (cls == 2'd2) ? "I" : (cls == 2'd1) ? "N" : "R";
            5'd11: status_char = (cls == 2'd2) ? "T" : (cls == 2'd1) ? "O" : "M";
            5'd12: status_char = (cls == 2'd2) ? "I" : (cls == 2'd1) ? "R" : "A";
            5'd13: status_char = (cls == 2'd2) ? "C" : (cls == 2'd1) ? "M" : "L";
            5'd14: status_char = (cls == 2'd2) ? "A" : (cls == 2'd1) ? "A" : " ";
            5'd15: status_char = (cls == 2'd2) ? "L" : (cls == 2'd1) ? "L" : " ";
            default: status_char = " ";
        endcase
    end
endfunction

function [7:0] confidence_char;
    input [4:0] idx;
    input [1:0] conf;
    begin
        case (idx)
            5'd0: confidence_char = "C";
            5'd1: confidence_char = "O";
            5'd2: confidence_char = "N";
            5'd3: confidence_char = "F";
            5'd4: confidence_char = ":";
            5'd5: confidence_char = " ";
            5'd6: confidence_char = (conf == 2'd2) ? "H" : (conf == 2'd1) ? "M" : "L";
            5'd7: confidence_char = (conf == 2'd2) ? "I" : (conf == 2'd1) ? "E" : "O";
            5'd8: confidence_char = (conf == 2'd2) ? "G" : (conf == 2'd1) ? "D" : "W";
            5'd9: confidence_char = (conf == 2'd2) ? "H" : " ";
            default: confidence_char = " ";
        endcase
    end
endfunction

function [7:0] ai_char;       // "AI READY"
    input [2:0] idx;
    begin
        case (idx)
            3'd0: ai_char = "A";
            3'd1: ai_char = "I";
            3'd2: ai_char = " ";
            3'd3: ai_char = "R";
            3'd4: ai_char = "E";
            3'd5: ai_char = "A";
            3'd6: ai_char = "D";
            3'd7: ai_char = "Y";
            default: ai_char = " ";
        endcase
    end
endfunction

function [7:0] spo2_value_char;
    input [4:0] idx;
    input [7:0] value;
    reg [7:0] clipped;
    begin
        clipped = (value > 8'd100) ? 8'd100 : value;
        case (idx)
            5'd0: spo2_value_char = "S";
            5'd1: spo2_value_char = "P";
            5'd2: spo2_value_char = "O";
            5'd3: spo2_value_char = "2";
            5'd4: spo2_value_char = ":";
            5'd5: spo2_value_char = " ";
            5'd6: spo2_value_char = (clipped >= 8'd100) ? "1" : digit_tens_0_99(clipped);
            5'd7: spo2_value_char = (clipped >= 8'd100) ? "0" : digit_ones_0_99(clipped);
            5'd8: spo2_value_char = (clipped >= 8'd100) ? "0" : "%";
            5'd9: spo2_value_char = (clipped >= 8'd100) ? "%" : " ";
            default: spo2_value_char = " ";
        endcase
    end
endfunction

function [7:0] temp_value_char;
    input [5:0] idx;
    input [7:0] raw;
    reg [7:0] temp_c;
    begin
        temp_c = {1'b0, raw[7:1]};
        case (idx)
            6'd0: temp_value_char = "T";
            6'd1: temp_value_char = "E";
            6'd2: temp_value_char = "M";
            6'd3: temp_value_char = "P";
            6'd4: temp_value_char = ":";
            6'd5: temp_value_char = " ";
            6'd6: temp_value_char = digit_tens_0_99(temp_c);
            6'd7: temp_value_char = digit_ones_0_99(temp_c);
            6'd8: temp_value_char = ".";
            6'd9: temp_value_char = raw[0] ? "5" : "0";
            6'd10: temp_value_char = " ";
            6'd11: temp_value_char = "C";
            default: temp_value_char = " ";
        endcase
    end
endfunction

// ── Chọn ký tự văn bản + màu (một tầng tổ hợp, đưa vào thanh ghi ở tầng kế)
reg [7:0]  char_ascii;
reg [4:0]  text_fg_idx;
reg [4:0]  text_bg_idx;
reg        text_scale;
reg [11:0] char_x_sel;
reg [11:0] char_y_sel;

wire [23:0] text_fg_color = palette_rgb(text_fg_idx);
wire [23:0] text_bg_color = palette_rgb(text_bg_idx);

always @(*) begin
    char_ascii    = " ";
    text_fg_idx   = IDX_WHITE;
    text_bg_idx   = IDX_DARK;
    text_scale    = 1'b0;
    char_x_sel    = char_x;
    char_y_sel    = TEXT_Y_CARDS;

    if (in_banner_text) begin
        text_scale = 1'b1;
        char_x_sel = char_x_b;
        char_y_sel = TEXT_Y_BANNER;
        if (char_col_b < 8'd25) begin                     // vùng STATUS (px 0..399)
            char_ascii    = (char_col_b < 8'd16) ? status_char(char_col_b[4:0], class_out) : " ";
            text_bg_idx   = class_idx;
            text_fg_idx   = (class_out == 2'd1) ? IDX_BLACK : IDX_WHITE;
        end else if (char_col_b < 8'd50) begin            // vùng CONF (px 400..799)
            char_ascii    = ((char_col_b - 8'd25) < 8'd10) ?
                            confidence_char(char_col_b - 8'd25, confidence) : " ";
            text_bg_idx   = conf_idx;
            text_fg_idx   = (confidence == 2'd1) ? IDX_BLACK : IDX_WHITE;
        end else begin                                    // vùng AI READY (px 800..1279)
            char_ascii    = ((char_col_b - 8'd50) < 8'd8) ? ai_char(char_col_b - 8'd50) : " ";
            text_bg_idx   = IDX_DARK;
            text_fg_idx   = IDX_NORMAL;
        end
    end else if (in_cards_text) begin
        text_scale = 1'b0;
        char_x_sel = char_x;
        char_y_sel = TEXT_Y_CARDS;
        if (char_col < 9'd96) begin                        // vùng trống (đã gỡ thẻ EEG/ECG/EMG)
            char_ascii    = " ";
            text_bg_idx   = IDX_DARK;
        end else if (char_col < 9'd128) begin              // thẻ SpO2
            char_ascii    = ((char_col - 9'd96) < 9'd10) ?
                            spo2_value_char(char_col - 9'd96, spo2_raw) : " ";
            text_bg_idx   = spo2_low ? IDX_ABNORMAL : IDX_DARK;
            text_fg_idx   = spo2_low ? IDX_BLACK : IDX_WHITE;
        end else begin                                    // thẻ TEMP
            char_ascii    = ((char_col - 9'd128) < 9'd12) ?
                            temp_value_char(char_col - 9'd128, temp_raw) : " ";
            text_bg_idx   = temp_err ? IDX_ABNORMAL : IDX_DARK;
            text_fg_idx   = temp_err ? IDX_BLACK : IDX_WHITE;
        end
    end
end

// ── Lớp tổng hợp nền (tổ hợp, đánh chỉ số theo bảng màu) ─────────────────────
reg [4:0] osd_idx;
always @(*) begin
    if (!de) begin
        osd_idx = IDX_BLACK;
    end else if (hud_frame) begin
        osd_idx = IDX_FRAME;
    end else if (in_banner) begin
        if (hcount < 12'd400)      osd_idx = class_idx;   // banner STATUS
        else if (hcount < 12'd800) osd_idx = conf_idx;    // CONF
        else                       osd_idx = IDX_DARK;    // AI
    end else if (in_cards) begin
        if (hcount < 12'd768)       osd_idx = IDX_DARK;       // vùng trống (đã gỡ thẻ EEG/ECG/EMG)
        else if (hcount < 12'd1024) osd_idx = spo2_low  ? IDX_ABNORMAL : IDX_DARK;
        else                        osd_idx = temp_err  ? IDX_ABNORMAL : IDX_DARK;
    end else begin
        osd_idx = wave_rgb_to_idx(wave_pixel);   // màu bảng màu của vùng dạng sóng
    end
end

// ── Lớp biểu tượng (icon) ─────────────────────────────────────────────────────
// ĐÃ GỠ BỎ để giảm CLS (Phase 3 trim OSD). Toàn bộ icon_rom, pipeline icon,
// và nhánh icon trong composite đã được xoá.
//
// ── Pipeline điểm ảnh (an toàn định thời; tổng độ trễ = OSD_LATENCY = 5) ───────
//   S1     : đưa vào thanh ghi chọn-ký-tự + vị trí + ảnh chụp nền (osd_bg_s1)
//   u_text : dựng glyph 2 chu kỳ (ROM font BSRAM có thanh ghi) -> text @ +3
//   s2/s3  : căn nền với text_pixel                            -> osd_bg @ +3
//   S4     : mux ưu tiên (text/nền)           -> chỉ số màu
//   S5     : tra CLUT có thanh ghi                             -> r/g/b
reg [7:0]  char_ascii_s1;
reg [11:0] char_x_s1, char_y_s1, hcount_s1, vcount_s1;
reg [23:0] fg_s1, bg_s1;
reg [4:0]  fg_idx_s1, fg_idx_s2, fg_idx_s3;
reg [4:0]  osd_bg_s1, osd_bg_s2, osd_bg_s3;
reg        scale_s1;

always @(posedge pixel_clk or negedge rst_n) begin
    if (!rst_n) begin
        char_ascii_s1 <= 8'h20;
        char_x_s1 <= 12'd0; char_y_s1 <= TEXT_Y_CARDS;
        hcount_s1 <= 12'd0; vcount_s1 <= 12'd0;
        fg_s1 <= 24'd0; bg_s1 <= 24'd0;
        fg_idx_s1 <= IDX_WHITE; fg_idx_s2 <= IDX_WHITE; fg_idx_s3 <= IDX_WHITE;
        osd_bg_s1 <= IDX_BLACK; osd_bg_s2 <= IDX_BLACK; osd_bg_s3 <= IDX_BLACK;
        scale_s1 <= 1'b0;
    end else begin
        char_ascii_s1 <= char_ascii;
        char_x_s1     <= char_x_sel;
        char_y_s1     <= char_y_sel;
        hcount_s1     <= hcount;
        vcount_s1     <= vcount;
        fg_s1         <= text_fg_color;
        bg_s1         <= text_bg_color;
        fg_idx_s1     <= text_fg_idx;
        fg_idx_s2     <= fg_idx_s1;
        fg_idx_s3     <= fg_idx_s2;
        osd_bg_s1     <= osd_idx;
        osd_bg_s2     <= osd_bg_s1;
        osd_bg_s3     <= osd_bg_s2;
        scale_s1      <= text_scale;
    end
end

wire [23:0] text_pixel;
wire        text_cell_on;

text_renderer u_text (
    .pixel_clk(pixel_clk),
    .rst_n(rst_n),
    .hcount(hcount_s1),
    .vcount(vcount_s1),
    .char_ascii(char_ascii_s1),
    .char_x(char_x_s1),
    .char_y(char_y_s1),
    .scale(scale_s1),
    .fg_color(fg_s1),
    .bg_color(bg_s1),
    .bg_en(1'b1),
    .pixel_out(text_pixel),
    .pixel_on(text_cell_on)
);

// ── Tổng hợp cuối: text > nền (đều căn ở +3), rồi CLUT ──────────────────────
reg [4:0] composite_idx_s4;

always @(posedge pixel_clk or negedge rst_n) begin
    if (!rst_n) begin
        composite_idx_s4 <= IDX_BLACK;
    end else if (text_cell_on) begin
        composite_idx_s4 <= fg_idx_s3;
    end else begin
        composite_idx_s4 <= osd_bg_s3;
    end
end

always @(posedge pixel_clk or negedge rst_n) begin
    if (!rst_n) begin
        r_out <= 8'd0; g_out <= 8'd0; b_out <= 8'd0;
    end else begin
        {r_out, g_out, b_out} <= clut_rom[composite_idx_s4];
    end
end

endmodule
