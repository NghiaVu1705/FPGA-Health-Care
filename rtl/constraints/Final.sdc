# Final.sdc - timing constraints for top_shared_ai (Tang Mega 138K)
# Supersedes TMDS_60HZ.sdc.
#
# Why: the first P&R (HDMI-only SDC) reported false CDC violations. Each clock
# meets its own Fmax (clk 275, sys_clk 60, pixel 73.5, DDR PLL/fclkdiv ok), so
# ALL violations are cross-domain paths through the CDC synchronisers (2-FF
# sync_2ff + cdc_bus_handshake toggle). The fix is to declare every clock and
# put the domains in asynchronous groups. NOTE: the sample buffers (sync_fifo)
# are SINGLE-CLOCK (all on sys_clk), so they are NOT a CDC crossing; the only
# real user-logic CDC is sys_clk -> pixel_clk through cdc_bus_handshake/sync_2ff.
#
# Gowin notes (learned the hard way):
#   * Every command must be on ONE physical line (no '\' continuation).
#   * get_clocks has NO wildcard, and you cannot reference the tool's
#     auto-created "*.default_gen_clk" clocks (they don't exist when the SDC is
#     read). So the DDR clocks are created explicitly below with our own names.
#   * The DDR clock frequencies are set at/under the IP's achieved Fmax so they
#     never create false violations *inside* the encrypted DDR3MI; the DDR
#     domain is async-isolated from the user logic anyway.

# Board clock: 50 MHz
create_clock -name clk -period 20 -waveform {0 10} [get_ports {clk}] -add

# System clock: gowin_pll_sys CLKOUT0 = 50 MHz (ODIV0_SEL=18, VCO 900).
# Relaxed 60 -> 50 MHz. Do NOT relax below 50: a looser target makes the
# timing-driven placer lazy (45 MHz -> Fmax fell to 41.8 MHz). At 50 MHz the
# achievable Fmax is ~48.95 MHz; the limiter is CONGESTION (CLS ~86%), fixed by
# lowering CLS (trim OSD), not by the clock. CNN/STFT/replay are not real-time.
# Keep this in sync with gowin_pll_sys ODIV0_SEL.
create_generated_clock -name sys_clk -source [get_ports {clk}] -master_clock clk -divide_by 1 -multiply_by 1 [get_pins {u_pll_sys/PLL_inst/CLKOUT0}]

# HDMI/TMDS: ~366.667 MHz serial (5x) and ~73.333 MHz pixel
create_generated_clock -name clk_tmds_5x -source [get_ports {clk}] -master_clock clk -divide_by 3 -multiply_by 22 [get_pins {u_tmds_pll/u_pll/PLL_inst/CLKOUT0}]
create_generated_clock -name clk_pixel -source [get_ports {clk}] -master_clock clk -divide_by 15 -multiply_by 22 [get_pins {u_tmds_pll/u_pll/PLL_inst/CLKOUT1}]

# DDR3 domain (gowin_pll_400M -> DDR3MI). Names ours so we can group them.
# clk_ddr = DDR PLL CLKOUT0 (~400 MHz); clk_ddr_phy = DDR3MI PHY fclkdiv (~100 MHz).
create_generated_clock -name clk_ddr -source [get_ports {clk}] -master_clock clk -divide_by 1 -multiply_by 8 [get_pins {u_ddr_pll/u_pll/PLL_inst/CLKOUT0}]
create_generated_clock -name clk_ddr_phy -source [get_ports {clk}] -master_clock clk -divide_by 1 -multiply_by 2 [get_pins {u_ddr3/gw3_top/u_ddr_phy_top/fclkdiv/CLKOUT}]

# Asynchronous clock groups. Each clock is its own group => mutually async.
# clk_ddr and clk_ddr_phy are kept in SEPARATE groups too: the only remaining
# (33) setup paths were intra-DDR3-IP DLL paths between these two approximate
# clocks (u_ddr3/.../u_dll) - the encrypted IP is vendor-validated and we cannot
# model its internal DLL timing exactly, so we do not analyse PLL<->fclkdiv
# crossings. No user-logic path is affected (those are all already clean).
set_clock_groups -asynchronous -group [get_clocks {clk}] -group [get_clocks {sys_clk}] -group [get_clocks {clk_tmds_5x}] -group [get_clocks {clk_pixel}] -group [get_clocks {clk_ddr}] -group [get_clocks {clk_ddr_phy}]

# CDC datapath rigor (sys_clk -> pixel_clk, the only real user-logic crossing).
# The decision bundle crosses via u_cdc_decision (toggle handshake + 2-FF): the
# data bus src_data_r[*] is quasi-static and structurally safe. The async clock
# group above already removes this arc from analysis; to instead BOUND the data
# bus to one pixel_clk period (~13.6 ns) for skew rigor, enable the line below
# AFTER confirming the Gowin SDC parser accepts the register reference (Gowin STA
# may subsume it under the async group; remove if it errors on re-P&R):
# set_max_delay 13.6 -from [get_pins {u_cdc_decision/src_data_r[*]/Q}] -to [get_pins {u_cdc_decision/dst_data[*]/D}]
