# Read back constraints actually loaded by Vivado. Never assign or waive them here.
proc video_platform_pin_audit {report_path} {
 set fd [open $report_path w]
 foreach {name ball standard} {
  {led[0]} J1 LVCMOS15 {led[1]} M6 LVCMOS15 sys_rst F8 LVCMOS15
  PJTAG_TCK AB15 LVCMOS33 PJTAG_TMS AB14 LVCMOS33
  PJTAG_TDI AD15 LVCMOS33 PJTAG_TDO AD16 LVCMOS33
 } {
  set port [get_ports -quiet $name]
  if {[llength $port] != 1} {close $fd; error "Expected one retained port: $name"}
  set actual_ball [get_property PACKAGE_PIN $port]
  set actual_standard [get_property IOSTANDARD $port]
  puts $fd "$name PACKAGE_PIN=$actual_ball IOSTANDARD=$actual_standard expected=$ball/$standard"
  if {$actual_ball ne $ball || $actual_standard ne $standard} {
   close $fd
   error "Retained pin constraint missing or changed: $name"
  }
 }
 puts $fd "ports_verified=7 attributes_verified=14 board_verified=false"
 close $fd
}
