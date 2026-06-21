#==============================================================================
# accel_timing.xdc  --  Timing constraints for the accelerator.
#
# Board pin assignments (DDR3, UART, sysclk) come from the MIG / board files in
# the block design. This file only constrains the accelerator's AXI clock.
#
# Target: 150 MHz (safe on K7-2 for the 16x32 INT8 datapath). Tighten to 200 MHz
# (5.0 ns) after timing closure if slack allows.
#==============================================================================
create_clock -name aclk -period 6.667 [get_ports aclk]   ;# 150 MHz

# AXI4-Lite control is quasi-static; relax cross-domain paths if VEGA runs slower
# set_clock_groups -asynchronous -group [get_clocks aclk] -group [get_clocks <vega_clk>]

#------------------------------------------------------------------------------
# UART diagnostic pins (Genesys 2 USB-UART). Only needed when accel_top is the
# top-level module (not when packaged as IP inside a block design). VERIFY pin
# names/locations against the official Genesys 2 master XDC before use.
#------------------------------------------------------------------------------
# set_property -dict { PACKAGE_PIN Y20 IOSTANDARD LVCMOS33 } [get_ports uart_tx_o] ;# FPGA->host
# set_property -dict { PACKAGE_PIN Y23 IOSTANDARD LVCMOS33 } [get_ports uart_rx_i] ;# host->FPGA
