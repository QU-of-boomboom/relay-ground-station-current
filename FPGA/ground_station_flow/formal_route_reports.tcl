# Read-only report collection can also inspect a preserved routed checkpoint.
set gs_report_flow [file dirname [info script]]
source [file join $gs_report_flow video_npu_body_guard.tcl]
source [file join $gs_report_flow video_platform_pin_audit.tcl]
video_npu_verify [file join [pwd] npu_body_before_opt.tsv] npu_body_after_route.txt
video_boundary_evidence npu_boundary_after_route.txt
video_platform_pin_audit platform_pins_after_route.txt
report_timing_summary -report_unconstrained -file board_implemented_timing.rpt
report_timing -max_paths 25 -file board_setup_paths.rpt
report_timing -delay_type min -max_paths 25 -file board_hold_paths.rpt
report_utilization -hierarchical -file board_implemented_utilization.rpt
report_route_status -file board_route_status.rpt
report_cdc -details -file board_implemented_cdc.rpt
report_bus_skew -file board_bus_skew.rpt
report_exceptions -ignored -file board_ignored_exceptions.rpt
report_drc -verbose -no_waivers -file board_drc.rpt
set gs_drc_state [open board_drc_check_states.tsv w]
foreach gs_check [lsort [get_drc_checks]] {
 puts $gs_drc_state "$gs_check\t[get_property IS_ENABLED $gs_check]\t[get_property SEVERITY $gs_check]"
}
close $gs_drc_state
check_timing -verbose -file board_check_timing.rpt
write_checkpoint -force board_implemented.dcp
# These are diagnostic reports. A successful Tcl return is not timing signoff.
