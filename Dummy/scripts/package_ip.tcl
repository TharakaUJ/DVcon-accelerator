#==============================================================================
# package_ip.tcl  --  Package accel_top as an AXI peripheral for IP Integrator.
#
# Run AFTER create_project.tcl, in the same Vivado session, or:
#   vivado -mode batch -source scripts/create_project.tcl -source scripts/package_ip.tcl
#
# Produces an IP in <root>/ip_repo that you add to your block design next to the
# VEGA core + MIG. Vivado auto-infers:
#   * S_AXIL (AXI4-Lite slave)  from s_axil_*
#   * M_AXI  (AXI4 master)      from m_axi_*
#   * aclk/aresetn clock+reset, irq interrupt
#==============================================================================
set root    [file normalize [file dirname [info script]]/..]
set ip_repo $root/ip_repo

ipx::package_project -root_dir $ip_repo -vendor user.org -library accel \
    -taxonomy /UserIP -module accel_top -import_files -force

set core [ipx::current_core]
set_property name        zeroshot_accel        $core
set_property display_name {Zero-Shot Detection Accelerator} $core
set_property description  {YOLO26n INT8 conv engine, AXI4-Lite ctrl + AXI4 master} $core
set_property vendor_display_name {DVCon} $core
set_property version 1.0 $core

# associate clock with both AXI interfaces
ipx::associate_bus_interfaces -busif S_AXIL -clock aclk $core
ipx::associate_bus_interfaces -busif M_AXI  -clock aclk $core

ipx::create_xgui_files $core
ipx::update_checksums  $core
ipx::save_core         $core

puts "IP packaged into: $ip_repo"
puts "Add it: settings > IP > Repository > add $ip_repo, then drop 'zeroshot_accel' in your BD."
