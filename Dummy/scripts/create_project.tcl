#==============================================================================
# create_project.tcl  --  Build the accelerator Vivado project for Genesys 2.
#
#   cd 0Accelaraator
#   vivado -mode batch -source scripts/create_project.tcl
#
# Genesys 2 part: Kintex-7 XC7K325T-2FFG900C.
#==============================================================================
set proj   accel_prj
set part   xc7k325tffg900-2
set root   [file normalize [file dirname [info script]]/..]

create_project $proj $root/$proj -part $part -force

# ---- RTL sources (SystemVerilog) ----
# SiLU ROM is computed at elaboration inside silu_lut.sv -- no hex file needed.
add_files -norecurse [glob $root/rtl/*.sv]

set_property top accel_top [current_fileset]
set_property -name {xsim.simulate.runtime} -value {all} -objects [current_fileset -simset] 2>/dev/null

# ---- simulation ----
add_files -fileset sim_1 -norecurse $root/sim/tb_datapath.sv
add_files -fileset sim_1 -norecurse $root/sim/tb_matmul.sv
# default sim top = matmul check; switch with: set_property top tb_datapath [get_filesets sim_1]
set_property top tb_matmul [get_filesets sim_1]

# ---- constraints (timing only; board pins come from the block design) ----
add_files -fileset constrs_1 -norecurse $root/constraints/accel_timing.xdc

puts "Project created: $root/$proj"
puts "Next:"
puts "  * run datapath sim:  launch_simulation"
puts "  * synth check:       launch_runs synth_1 -jobs 4"
puts "  * package as IP:     source scripts/package_ip.tcl"
