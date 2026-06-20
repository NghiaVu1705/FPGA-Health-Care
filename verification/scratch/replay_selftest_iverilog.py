#!/usr/bin/env python3
"""Functional check of the multi-channel Signal Replay self-test (Icarus Verilog).

Drives the REAL ``top_shared_ai`` RTL (debouncer + replay FSM + replay_rom +
FIFO write MUX + real ``sync_fifo``).  Every heavy vendor/child module
(PLLs, DDR3, BSRAM, serial slaves, display, and the AI core) is replaced by a
small behavioural stub.  The AI-core stub continuously drains the three FIFOs
(with a deliberate back-pressure stall window) so an entire 2048-sample replay
can flow through and be captured.

It presses ``case_next_n`` (AB13), captures the per-channel sample stream read
out of each FIFO, and asserts it is byte-identical to Final/test_{eeg,ecg,emg}.hex
in order and length (2048 each).  Also checks the single vitals pulse.

Run:  software/.venv/bin/python verification/scratch/replay_selftest_iverilog.py
Needs: iverilog, vvp on PATH.
"""

from __future__ import annotations

import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
TOP = REPO / "rtl/top/top_shared_ai.v"
FIFO = REPO / "rtl/common/sync_fifo.v"
# Replay hex live next to top_shared_ai.v (rtl/top/) — where GowinSynthesis
# resolves the bare-name $readmemh, same as font8x16.hex in rtl/display/.
FINAL = REPO / "rtl" / "top"

STUBS = r"""
`timescale 1ns/1ps
// ---- clock/reset/vendor stubs ---------------------------------------------
module gowin_pll_sys (output clkout0, output lock, input clkin);
    assign clkout0 = clkin; assign lock = 1'b1;
endmodule

module TMDS_PLL (input clkin, input init_clk, output clkout0, output clkout1, output lock);
    assign clkout0 = clkin; assign clkout1 = clkin; assign lock = 1'b1;
endmodule

module Gowin_PLL (input clkin, input init_clk, input enclk0, input enclk1, input enclk2,
                  output clkout0, output clkout1, output clkout2, output lock, input reset);
    assign clkout0 = clkin; assign clkout1 = clkin; assign clkout2 = clkin; assign lock = 1'b1;
endmodule

module reset_sync (input clk, input rst_async_n, output reg rst_sync_n);
    reg meta;
    always @(posedge clk or negedge rst_async_n)
        if (!rst_async_n) {rst_sync_n, meta} <= 2'b00;
        else              {rst_sync_n, meta} <= {meta, 1'b1};
endmodule

module gowin_bsram_hamming (input clk, input [5:0] addr, output reg [7:0] dout);
    always @(posedge clk) dout <= 8'd0;
endmodule

module gowin_bsram_twiddle (input clk, input [4:0] addr, output reg [31:0] dout);
    always @(posedge clk) dout <= 32'd0;
endmodule

module DDR3MI (
    input clk, input pll_stop, input memory_clk, input pll_lock, input rst_n,
    output clk_out, output ddr_rst, output init_calib_complete,
    output cmd_ready, input [2:0] cmd, input cmd_en, input [28:0] addr,
    output wr_data_rdy, input [255:0] wr_data, input wr_data_en, input wr_data_end,
    input [31:0] wr_data_mask, output [255:0] rd_data, output rd_data_valid,
    output rd_data_end, input sr_req, input ref_req, output sr_ack, output ref_ack,
    input burst,
    output [14:0] O_ddr_addr, output [2:0] O_ddr_ba, output O_ddr_cs_n,
    output O_ddr_ras_n, output O_ddr_cas_n, output O_ddr_we_n, output O_ddr_clk,
    output O_ddr_clk_n, output O_ddr_cke, output O_ddr_odt, output O_ddr_reset_n,
    output [3:0] O_ddr_dqm, inout [31:0] IO_ddr_dq, inout [3:0] IO_ddr_dqs,
    inout [3:0] IO_ddr_dqs_n);
    assign clk_out = clk; assign ddr_rst = 1'b0;
    assign init_calib_complete = 1'b1; assign cmd_ready = 1'b1;
    assign wr_data_rdy = 1'b1; assign rd_data = 256'd0;
    assign rd_data_valid = 1'b0; assign rd_data_end = 1'b0;
    assign sr_ack = 1'b0; assign ref_ack = 1'b0;
    assign O_ddr_addr = 0; assign O_ddr_ba = 0; assign O_ddr_cs_n = 0;
    assign O_ddr_ras_n = 0; assign O_ddr_cas_n = 0; assign O_ddr_we_n = 0;
    assign O_ddr_clk = 0; assign O_ddr_clk_n = 0; assign O_ddr_cke = 0;
    assign O_ddr_odt = 0; assign O_ddr_reset_n = 0; assign O_ddr_dqm = 0;
endmodule

// ---- weight boot loader: report done quickly so the top boot FSM reaches
//      BOOT_RUN (boot_run_enable=1) and releases the AI core. This self-test
//      only exercises the replay FIFO/debounce path, not the weight image.
module weight_boot_loader (
    input sys_clk, input rst_n, input start,
    output busy, output reg done, output error, output crc_error,
    input [7:0] flash_data, input flash_valid, output flash_ready,
    output header_valid, output entry_valid, output [15:0] entries_loaded,
    output [15:0] entry_count_out, output [31:0] image_len_out,
    output [15:0] entry_kind_out, output [31:0] entry_flash_offset_out,
    output [28:0] entry_ddr_addr_out, output [31:0] entry_size_out,
    output [31:0] entry_crc32_out, output [31:0] current_entry_flash_offset,
    output [28:0] current_entry_ddr_addr, output [31:0] current_entry_size,
    input ddr_cmd_ready, output [2:0] ddr_cmd, output ddr_cmd_en, output [28:0] ddr_addr,
    input ddr_wr_data_rdy, output [255:0] ddr_wr_data, output ddr_wr_data_en,
    output ddr_wr_data_end, output [31:0] ddr_wr_data_mask);
    assign flash_ready = 1'b1;
    assign busy = 1'b0; assign error = 1'b0; assign crc_error = 1'b0;
    reg [4:0] cnt;
    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) begin cnt <= 5'd0; done <= 1'b0; end
        else if (start) begin cnt <= 5'd1; done <= 1'b0; end
        else if (cnt != 5'd0 && cnt < 5'd20) cnt <= cnt + 5'd1;
        else if (cnt == 5'd20) done <= 1'b1;
    end
    assign header_valid = 1'b0; assign entry_valid = 1'b0; assign entries_loaded = 16'd0;
    assign entry_count_out = 16'd0; assign image_len_out = 32'd0; assign entry_kind_out = 16'd0;
    assign entry_flash_offset_out = 32'd0; assign entry_ddr_addr_out = 29'd0;
    assign entry_size_out = 32'd0; assign entry_crc32_out = 32'd0;
    assign current_entry_flash_offset = 32'd0; assign current_entry_ddr_addr = 29'd0;
    assign current_entry_size = 32'd0;
    assign ddr_cmd = 3'd0; assign ddr_cmd_en = 1'b0; assign ddr_addr = 29'd0;
    assign ddr_wr_data = 256'd0; assign ddr_wr_data_en = 1'b0; assign ddr_wr_data_end = 1'b0;
    assign ddr_wr_data_mask = 32'hffff_ffff;
endmodule

// ---- serial slaves: idle (no live sensor traffic) -------------------------
module uart_top #(parameter CLK_FRE = 0, parameter BAUD_RATE = 0) (
    input sys_clk, input rst_n, input uart_rx, output uart_tx,
    output [15:0] emg_sample, output emg_valid,
    input [7:0] dbg_data, input dbg_valid, output dbg_ready);
    assign uart_tx = 1'b1; assign emg_sample = 16'd0; assign emg_valid = 1'b0;
    assign dbg_ready = 1'b1;
endmodule

module spi_slave (input sys_clk, input rst_n, input spi_sck, input spi_mosi,
    input spi_cs_n, output [15:0] rx_data, output rx_valid, output [1:0] channel);
    assign rx_data = 16'd0; assign rx_valid = 1'b0; assign channel = 2'd0;
endmodule

module i2c_slave #(parameter I2C_ADDR = 7'h00) (
    input sys_clk, input rst_n, input scl, inout sda,
    output [7:0] spo2_raw, output [7:0] temp_raw, output data_updated);
    assign spo2_raw = 8'd0; assign temp_raw = 8'd0; assign data_updated = 1'b0;
endmodule

// ---- AI core stub: drains all three FIFOs, with a back-pressure stall window
module biomed_shared_ai_system (
    input sys_clk, input rst_n,
    input signed [15:0] eeg_sample, input eeg_valid, output eeg_ready,
    input signed [15:0] ecg_sample, input ecg_valid, output ecg_ready,
    input signed [15:0] emg_sample, input emg_valid, output emg_ready,
    input [7:0] spo2_raw, input [7:0] temp_raw, input vitals_updated,
    output [5:0] hamming_rom_addr, input [7:0] hamming_rom_data,
    output [4:0] twiddle_rom_addr, input [31:0] twiddle_rom_data,
    input ddr_cmd_ready, output [2:0] ddr_cmd, output ddr_cmd_en,
    output [28:0] ddr_addr, input [255:0] ddr_rd_data, input ddr_rd_data_valid,
    input ddr_rd_data_end,
    output [1:0] active_channel, output ai_busy, output weights_ready,
    output weight_prefetch_error, output cnn_timeout_error,
    output [1:0] final_class, output [4:0] triggered_sensors,
    output [1:0] confidence, output decision_update);
    // Free-running cycle counter to shape a stall window.
    reg [31:0] cyc;
    always @(posedge sys_clk or negedge rst_n)
        if (!rst_n) cyc <= 32'd0; else cyc <= cyc + 32'd1;
    // Hold reads off long enough to fill the 2048-deep FIFOs completely so the
    // looping replay FSM stalls on *_fifo_full, then release to prove it resumes
    // losslessly (first 2048 samples still arrive in order).
    wire ready = (cyc >= 32'd73000);
    assign eeg_ready = ready; assign ecg_ready = ready; assign emg_ready = ready;
    assign hamming_rom_addr = 6'd0; assign twiddle_rom_addr = 5'd0;
    assign ddr_cmd = 3'd0; assign ddr_cmd_en = 1'b0; assign ddr_addr = 29'd0;
    assign active_channel = 2'd0; assign ai_busy = 1'b0; assign weights_ready = 1'b1;
    assign weight_prefetch_error = 1'b0; assign cnn_timeout_error = 1'b0;
    assign final_class = 2'd0; assign triggered_sensors = 5'd0;
    assign confidence = 2'd0; assign decision_update = 1'b0;
endmodule

// ---- display path: irrelevant to replay, stub idle ------------------------
module sync_2ff (input dst_clk, input dst_rst_n, input async_in, output sync_out);
    assign sync_out = 1'b0;
endmodule

module cdc_bus_handshake #(parameter WIDTH = 1) (
    input src_clk, input src_rst_n, input [WIDTH-1:0] src_data, input src_update,
    input dst_clk, input dst_rst_n, output [WIDTH-1:0] dst_data, output dst_update);
    assign dst_data = {WIDTH{1'b0}}; assign dst_update = 1'b0;
endmodule

module vga_timing #(parameter H_ACTIVE=0,H_FP=0,H_SYNC=0,H_BP=0,
                    V_ACTIVE=0,V_FP=0,V_SYNC=0,V_BP=0,HS_POL=0,VS_POL=0) (
    input clk, input rst, output hs, output vs, output de,
    output [11:0] active_x, output [11:0] active_y);
    assign hs=0; assign vs=0; assign de=0; assign active_x=0; assign active_y=0;
endmodule

module waveform_display (
    input sys_clk, input rst_n, input pixel_clk, input pixel_rst_n,
    input [7:0] eeg_sample, input eeg_valid, input [7:0] ecg_sample, input ecg_valid,
    input [7:0] emg_sample, input emg_valid, input [11:0] hcount, input [11:0] vcount,
    input de, output [23:0] pixel_out);
    assign pixel_out = 24'd0;
endmodule

module osd_overlay (
    input pixel_clk, input rst_n, input [11:0] hcount, input [11:0] vcount, input de,
    input [1:0] class_out, input [4:0] triggered_sensors, input [1:0] confidence,
    input [7:0] spo2_raw, input [7:0] temp_raw, input [23:0] wave_pixel,
    output [7:0] r_out, output [7:0] g_out, output [7:0] b_out);
    assign r_out=0; assign g_out=0; assign b_out=0;
endmodule

module DVI_TX_Top (
    input I_rst_n, input I_serial_clk, input I_rgb_clk, input I_rgb_vs, input I_rgb_hs,
    input I_rgb_de, input [7:0] I_rgb_r, input [7:0] I_rgb_g, input [7:0] I_rgb_b,
    output O_tmds_clk_p, output O_tmds_clk_n, output [2:0] O_tmds_data_p,
    output [2:0] O_tmds_data_n);
    assign O_tmds_clk_p=0; assign O_tmds_clk_n=0; assign O_tmds_data_p=0; assign O_tmds_data_n=0;
endmodule
"""

TB = r"""
`timescale 1ns/1ps
module tb_replay;
    reg clk = 0;
    reg rst_n = 0;
    reg case_next_n = 1'b1;   // released (active-low, pull-up)

    wire uart_tx_debug, spi_unused;
    wire [14:0] ddr_addr; wire [2:0] ddr_bank;
    wire ddr_cs, ddr_ras, ddr_cas, ddr_we, ddr_ck, ddr_ck_n, ddr_cke, ddr_odt, ddr_reset_n;
    wire [3:0] ddr_dm; wire [31:0] ddr_dq; wire [3:0] ddr_dqs, ddr_dqs_n;
    wire tmds_clk_n_0, tmds_clk_p_0; wire [2:0] tmds_d_n_0, tmds_d_p_0;

    top_shared_ai dut (
        .clk(clk), .rst_n(rst_n), .case_next_n(case_next_n),
        .uart_rx_emg(1'b1), .uart_tx_debug(uart_tx_debug),
        .spi_sck(1'b0), .spi_mosi(1'b0), .spi_cs_n(1'b1),
        .i2c_scl(1'b1), .i2c_sda(),
        .ddr_addr(ddr_addr), .ddr_bank(ddr_bank), .ddr_cs(ddr_cs), .ddr_ras(ddr_ras),
        .ddr_cas(ddr_cas), .ddr_we(ddr_we), .ddr_ck(ddr_ck), .ddr_ck_n(ddr_ck_n),
        .ddr_cke(ddr_cke), .ddr_odt(ddr_odt), .ddr_reset_n(ddr_reset_n), .ddr_dm(ddr_dm),
        .ddr_dq(ddr_dq), .ddr_dqs(ddr_dqs), .ddr_dqs_n(ddr_dqs_n),
        .tmds_clk_n_0(tmds_clk_n_0), .tmds_clk_p_0(tmds_clk_p_0),
        .tmds_d_n_0(tmds_d_n_0), .tmds_d_p_0(tmds_d_p_0)
    );

    always #5 clk = ~clk;

    // Capture FIFO read streams (FIFO Q is valid one cycle after *_fifo_rd).
    reg [15:0] cap_eeg [0:2047];
    reg [15:0] cap_ecg [0:2047];
    reg [15:0] cap_emg [0:2047];
    integer ne = 0, nc = 0, nm = 0;
    reg eeg_rd_d, ecg_rd_d, emg_rd_d;
    integer vit_pulses = 0;

    always @(posedge clk) begin
        if (!rst_n) begin
            eeg_rd_d <= 0; ecg_rd_d <= 0; emg_rd_d <= 0;
        end else begin
            eeg_rd_d <= dut.eeg_fifo_rd;
            ecg_rd_d <= dut.ecg_fifo_rd;
            emg_rd_d <= dut.emg_fifo_rd;
            if (eeg_rd_d && ne < 2048) begin cap_eeg[ne] = dut.eeg_sample; ne = ne + 1; end
            if (ecg_rd_d && nc < 2048) begin cap_ecg[nc] = dut.ecg_sample; nc = nc + 1; end
            if (emg_rd_d && nm < 2048) begin cap_emg[nm] = dut.emg_sample; nm = nm + 1; end
            if (dut.vitals_updated_rep) vit_pulses = vit_pulses + 1;
        end
    end

    integer t;
    initial begin
        rst_n = 0; repeat (20) @(posedge clk);
        rst_n = 1; repeat (10) @(posedge clk);
        // Press and hold the button so the debouncer (64Ki cycles) registers it.
        case_next_n = 1'b0;
        // Run until all three channels captured 2048 samples, or timeout.
        t = 0;
        while ((ne < 2048 || nc < 2048 || nm < 2048) && t < 400000) begin
            @(posedge clk); t = t + 1;
        end
        repeat (20) @(posedge clk);
        $writememh("cap_eeg.hex", cap_eeg);
        $writememh("cap_ecg.hex", cap_ecg);
        $writememh("cap_emg.hex", cap_emg);
        $display("CAPTURED eeg=%0d ecg=%0d emg=%0d vit_pulses=%0d cycles=%0d",
                 ne, nc, nm, vit_pulses, t);
        $finish;
    end
endmodule
"""


def _load_hex(path: Path) -> list[int]:
    out = []
    for ln in path.read_text().splitlines():
        s = ln.strip()
        if not s or s.startswith("//"):
            continue
        out.append(int(s, 16) & 0xFFFF)
    return out


def main() -> int:
    for f in ("test_eeg.hex", "test_ecg.hex", "test_emg.hex"):
        if not (FINAL / f).exists():
            print(f"ERROR: {FINAL / f} missing — run extract_sample.py first")
            return 1

    work = Path(tempfile.mkdtemp(prefix="replay_self_"))
    (work / "stubs.v").write_text(STUBS)
    (work / "tb_replay.v").write_text(TB)
    for f in ("test_eeg.hex", "test_ecg.hex", "test_emg.hex"):
        shutil.copy(FINAL / f, work / f)

    comp = subprocess.run(
        ["iverilog", "-g2012", "-o", "sim.vvp", "tb_replay.v", "stubs.v",
         str(TOP), str(FIFO)],
        cwd=work, capture_output=True, text=True)
    if comp.returncode != 0:
        print("=== iverilog COMPILE FAILED ===")
        print(comp.stdout + comp.stderr)
        return 1
    print("iverilog compile: OK (real top_shared_ai elaborated)")

    run = subprocess.run(["vvp", "sim.vvp"], cwd=work, capture_output=True, text=True)
    print(run.stdout.strip())
    if run.returncode != 0:
        print(run.stderr)
        return 1

    ok = True
    for name, cap in (("eeg", "cap_eeg.hex"), ("ecg", "cap_ecg.hex"), ("emg", "cap_emg.hex")):
        # One AB13 press selects replay_case=1 -> the FIRST stored window (CASE 1).
        # The per-channel hex now concatenates N case windows; check window 0.
        expected = _load_hex(FINAL / f"test_{name}.hex")[:2048]
        got = _load_hex(work / cap)[: len(expected)]
        if got == expected and len(got) == 2048:
            print(f"  {name.upper()}: 2048/2048 samples replayed in order  EXACT")
        else:
            ok = False
            n_match = sum(1 for a, b in zip(got, expected) if a == b)
            print(f"  {name.upper()}: MISMATCH ({n_match}/{len(expected)} match, captured {len(got)})")

    vit_ok = "vit_pulses=1" in run.stdout
    print(f"  vitals pulse exactly once: {'OK' if vit_ok else 'FAIL'}")
    ok &= vit_ok

    print("\n=== Replay self-test:", "PASS ===" if ok else "FAIL ===")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
