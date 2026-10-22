# Runs after INIT_DESIGN links all retained IP, in both GUI and batch flows.
# Only reports/assertions: no netlist, reset, latency, clock or exception edits.
set gs_audit_dir [file dirname [info script]]
# Vivado's implementation worker is an in-memory GateLvl project. Its fileset
# TOP is not the parent XPR's TOP; verify the actual parent before returning to
# the already linked design. This follows the retained official hook pattern.
set gs_parent [get_property parent.project_path [current_project]]
if {$gs_parent eq "" || ![file isfile $gs_parent]} {error "Missing implementation parent project"}
open_project $gs_parent
source [file join $gs_audit_dir formal_config.tcl]
gs_formal::check
gs_formal::snapshot parent_configuration.tsv
gs_formal::verify_controls parent_configuration.tsv [file join $gs_audit_dir expected_controls.tsv]
close_project
source [file join $gs_audit_dir video_trim_synthesis_audit.tcl]
file copy -force [file join $gs_audit_dir baseline_npu_primitives.tsv] baseline_npu_primitives.tsv
video_trim_audit 0
report_utilization -hierarchical -file board_linked_utilization.rpt
report_timing_summary -report_unconstrained -file board_linked_timing.rpt
report_cdc -details -file board_linked_cdc.rpt
report_clocks -file board_linked_clocks.rpt
set gs_audit [open board_constraint_objects.txt w]
foreach {box width} {Command_Inst 65 Response_Inst 33} {
 set base U_gs_station/Bridge_Inst/$box
 set launch [get_cells -hier -filter "NAME =~ $base/payload_reg*"]
 set capture [get_cells -hier -filter "NAME =~ $base/dst_data_reg*"]
 puts $gs_audit "$box sources=[llength $launch] sinks=[llength $capture] expected=$width"
 if {[llength $launch]<1 || [llength $launch]>$width || [llength $launch]!=[llength $capture]} {error "Mailbox live payload endpoint count invalid"}
 foreach sink $capture {
  set expected [string map {dst_data_reg payload_reg} $sink]
  set driver [get_pins -leaf -of_objects [get_nets -of_objects [get_pins $sink/D]] -filter {DIRECTION == OUT}]
  puts $gs_audit "payload $sink driver=$driver expected=$expected/Q"
  if {[llength $driver]!=1 || [get_property NAME $driver] ne "$expected/Q"} {error "Mailbox payload provenance mismatch"}
 }
 if {[llength [get_timing_paths -from $launch -to $capture -max_paths 1]]!=1} {error "Mailbox payload has no timing analysis"}
 report_timing -from $launch -to $capture -max_paths 3 -file ${box}_linked_timing.rpt
}
set gs_sync [get_pins -hier -regexp {U_gs_station/Bridge_Inst/.*(req_sync_reg|ack_sync_reg)\[0\]/D}]
set gs_notice [get_pins -hier -regexp {U_gs_station/ResetNotice_Inst/notice_sync_reg\[0\]/D}]
puts $gs_audit "mailbox_first_D=[llength $gs_sync] reset_notice_first_D=[llength $gs_notice]"
if {[llength $gs_sync]!=4 || [llength $gs_notice]!=1} {error "CDC synchronizer count changed"}
close $gs_audit
