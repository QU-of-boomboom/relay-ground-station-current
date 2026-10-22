# Open the SAME prepared XPR in either Vivado mode. No hidden set_property overrides.
set gs_entry_root [file dirname [file dirname [info script]]]
set gs_action [lindex $argv 0]
set gs_report [lindex $argv 1]
set gs_formal_report_owned false
proc gs_formal_ensure_run {run step} {
 set status [get_property STATUS [get_runs $run]]
 set progress [get_property PROGRESS [get_runs $run]]
 if {$progress eq "100%" && ![regexp -nocase {fail|error} $status]} {
  puts "FORMAL_REUSE_COMPLETE: $run $status"
  return
 }
 if {[regexp -nocase {running|queued} $status]} {
  puts "FORMAL_WAIT_EXISTING: $run $status"
 } elseif {[string equal -nocase $status "Not started"]} {
  if {$step eq ""} {launch_runs $run -jobs 2} else {launch_runs $run -to_step $step -jobs 2}
 } else {
  error "Run $run is incomplete/failed ($status); preserve logs and inspect its process/checkpoint before explicit recovery. No automatic reset or duplicate launch."
 }
 wait_on_run $run
 set status [get_property STATUS [get_runs $run]]
 if {[get_property PROGRESS [get_runs $run]] ne "100%" || [regexp -nocase {fail|error} $status]} {error "Run $run incomplete or failed: $status"}
}
proc gs_formal_main {gs_entry_root gs_action gs_report} {
global gs_formal_report_owned
# Load definitions before project I/O so early failures can use isolated reporting.
source [file join $gs_entry_root ground_station_flow formal_config.tcl]
if {$gs_action ni {audit gui synth route}} {error "Expected audit/gui/synth/route and a new report directory"}
if {[file exists $gs_report]} {error "Refusing to overwrite formal run evidence: $gs_report"}
file mkdir $gs_report
set gs_formal_report_owned true
open_project [file join $gs_entry_root fpai_demo_vivado.xpr]
gs_formal::check
update_compile_order -fileset sources_1
gs_formal::snapshot [file join $gs_report configuration.tsv]
gs_formal::verify_controls [file join $gs_report configuration.tsv] [file join $gs_entry_root ground_station_flow expected_controls.tsv]
if {$gs_action eq "audit"} {
 set gs_bit_hook [get_property STEPS.WRITE_BITSTREAM.TCL.PRE [get_runs impl_1]]
 set gs_rejected [catch {source $gs_bit_hook} gs_bit_reason]
 if {!$gs_rejected || ![string match "Formal board is not cleared for bitstream:*" $gs_bit_reason]} {error "Expected the unreleased bitstream guard to reject before vendor patch"}
 ::gs_formal_io::write_new [file join $gs_report bitstream_guard.txt] "rejected=true vendor_bitstream_hook_executed=false reason=$gs_bit_reason\n"
}
if {$gs_action in {synth route}} {
 gs_formal_ensure_run synth_1 ""
 if {$gs_action eq "route"} {
  gs_formal_ensure_run impl_1 route_design
  ::gs_formal_io::write_new [file join $gs_report implementation_status.txt] "[get_property STATUS [get_runs impl_1]]\n"
  if {[get_property PROGRESS [get_runs impl_1]] ne "100%" || [regexp -nocase {fail|error} [get_property STATUS [get_runs impl_1]]]} {error "Implementation incomplete or failed; preserve run reports"}
 }
}
::gs_formal_io::write_new [file join $gs_report COMPLETED.txt] "action=$gs_action configuration_checked=true board_verified=false implementation_signoff=false\n"
if {$gs_action ne "gui"} {close_project}
::gs_formal_io::close
}
set gs_catch_code [catch {gs_formal_main $gs_entry_root $gs_action $gs_report} gs_error gs_options]
if {$gs_catch_code} {
 set gs_error_detail "Tcl return code=$gs_catch_code result=$gs_error options=$gs_options"
 if {[dict exists $gs_options -errorinfo]} {set gs_error_detail [dict get $gs_options -errorinfo]}
 # File evidence and exit must not depend on GUI stdout/stderr channels.
 # EXCL prevents a failed invocation from overwriting earlier failure evidence.
 set gs_failure_report_code [catch {
  if {!$gs_formal_report_owned} {error "Failure report skipped: directory was not created by this invocation"}
  ::gs_formal_io::write_new [file join $gs_report FAILED.txt] "FORMAL_ENTRY_FAILED: $gs_error\n$gs_error_detail\n"
 } gs_failure_report_error]
 set gs_diagnostic "FORMAL_ENTRY_FAILED: $gs_error\n$gs_error_detail"
 if {$gs_failure_report_code} {append gs_diagnostic "\nFORMAL_FAILURE_EVIDENCE_WRITE_FAILED: $gs_failure_report_error"}
 if {[catch {::gs_formal_io::console_error $gs_diagnostic}]} {
  if {[catch {puts stderr $gs_diagnostic}]} {catch {puts $gs_diagnostic}}
 }
 catch {close_project}
 if {[catch {::gs_formal_io::close} gs_cleanup_error]} {
  catch {puts "FORMAL_IO_CLEANUP_FAILED_AFTER_ORIGINAL_ERROR: $gs_cleanup_error"}
 }
 exit 1
}
if {$gs_action ne "gui"} {exit 0}
