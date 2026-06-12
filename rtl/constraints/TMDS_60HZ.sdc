create_clock -name clk -period 20 -waveform {0 10} [get_ports {clk}] -add

# TMDS_PLL_60HZ_MOD in this source tree generates about 366.667 MHz serial
# and 73.333 MHz pixel clocks from the 50 MHz board clock.
create_generated_clock -name clk_tmds_5x -source [get_ports {clk}] -master_clock clk -divide_by 3 -multiply_by 22 [get_pins {u_tmds_pll/u_pll/PLL_inst/CLKOUT0}]
create_generated_clock -name clk_pixel -source [get_ports {clk}] -master_clock clk -divide_by 15 -multiply_by 22 [get_pins {u_tmds_pll/u_pll/PLL_inst/CLKOUT1}]

set_clock_groups -asynchronous -group [get_clocks {clk}] -group [get_clocks {clk_tmds_5x}] -group [get_clocks {clk_pixel}]
