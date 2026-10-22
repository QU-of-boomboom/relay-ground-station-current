# Each report I/O operation runs in the same installation's standalone Tcl.
# This isolates file channels from the active Vivado process; it is a bounded
# payload protocol, not evidence that the vendor/runtime root cause is known.
namespace eval ::gs_formal_io {
 variable child
 if {[info exists child] && $child ne ""} {error "Cannot replace formal I/O while an old interpreter is active"}
 set child ""
 variable maximum_bytes 4194304
 variable executable [file join [file dirname [info nameofexecutable]] tclsh85t.exe]
 variable helper [file join [file dirname [info script]] formal_file_io.tcl]
}
proc ::gs_formal_io::invoke {action path {input ""}} {
 variable executable; variable helper
 if {![file isfile $executable] || ![file isfile $helper]} {error "Missing same-installation formal file helper or Tcl executable"}
 # Direct argv, never a shell command. Both operations receive a dedicated
 # stdin pipe; writes send ASCII HEX to avoid Windows argv length limits.
 # No automatic retries; exec's original CHILDSTATUS/stderr options survive.
 set code [catch {exec -keepnewline -- $executable $helper $action $path << $input} result options]
 if {$code} {return -options $options $result}
 return $result
}
proc ::gs_formal_io::read_text {path} {
 variable maximum_bytes
 set response [invoke read $path]
 if {![regexp {^GS_FILE_IO_OK READ ([1-9][0-9]*) ([0-9a-f]+)\n$} $response whole length hex]} {error "Invalid standalone formal READ receipt"}
 if {$response ne "GS_FILE_IO_OK READ $length $hex\n" || [string length $length] > 7 || $length > $maximum_bytes || [string length $hex] != 2*$length} {
  error "Standalone formal READ receipt byte count mismatch"
 }
 set bytes [binary format H* $hex]
 set text [encoding convertfrom utf-8 $bytes]
 if {![string equal [encoding convertto utf-8 $text] $bytes]} {error "Formal report input is not exact UTF-8: $path"}
 return [string map [list "\r\n" "\n" "\r" "\n"] $text]
}
proc ::gs_formal_io::write_new {path text {newline crlf}} {
 variable maximum_bytes
 if {$newline ni {lf crlf}} {error "Formal output requires explicit lf/crlf translation"}
 if {$newline eq "crlf"} {set text [string map [list "\n" "\r\n"] $text]}
 set bytes [encoding convertto utf-8 $text]
 set length [string length $bytes]
 if {$length < 1 || $length > $maximum_bytes} {error "Formal output size rejected: $length bytes"}
 binary scan $bytes H* hex
 set response [invoke write $path $hex]
 if {$response ne "GS_FILE_IO_OK WRITE $length\n"} {error "Invalid standalone formal WRITE receipt"}
 return $length
}
proc ::gs_formal_io::console_error {text} {
 # Best effort only: FAILED uses the independent helper and original exit1
 # does not depend on a usable parent-interpreter console channel.
 if {![catch {puts stderr $text; flush stderr}]} {return}
 puts stdout $text
 flush stdout
}
proc ::gs_formal_io::close {} {
 # No long-lived interpreter, process, or channel is owned by this adapter.
 return
}

# Shared read-only configuration assertions for GUI and batch entry.
namespace eval gs_formal {
 variable defines {GS_COMPACT_STORAGE GS_LINK_SERVICE GS_SHARED_QUALITY GS_FROZEN_CONTROL GS_FROZEN_EVIDENCE GS_SEQUENCED_SERVICE GS_FROZEN_CACHE}
 proc require_equal {actual expected label} {
  if {$actual ne $expected} {error "Formal configuration mismatch: $label actual=<$actual> expected=<$expected>"}
 }
 proc check {} {
  variable defines
  require_equal [version -short] 2018.3 tool_version
  require_equal [get_property PART [current_project]] xc7z030ffg676-2 part
  foreach fs {sources_1 sim_1} {
   require_equal [get_property TOP [get_filesets $fs]] ai7030_edif_top $fs/top
   require_equal [get_property VERILOG_DEFINE [get_filesets $fs]] $defines $fs/defines
  }
  require_equal [llength [get_files -quiet */rtl/multinode_station/*.v]] 51 station_sources
  require_equal [llength [get_files -quiet */rtl/multinode_station/gs_unified_alarm_bank.v]] 1 unified_alarm_source
  foreach name {ground_station_cdc.xdc ground_station_platform_pins.xdc} {
   set f [get_files -quiet */$name]
   require_equal [llength $f] 1 $name/count
   require_equal [get_property USED_IN_SYNTHESIS $f] 0 $name/synthesis
   require_equal [get_property USED_IN_IMPLEMENTATION $f] 1 $name/implementation
   require_equal [get_property PROCESSING_ORDER $f] LATE $name/order
  }
  require_equal [get_property STEPS.PLACE_DESIGN.ARGS.DIRECTIVE [get_runs impl_1]] Explore placement
  require_equal [get_property STRATEGY [get_runs impl_1]] Performance_NetDelay_high strategy
  require_equal [get_property STEPS.PHYS_OPT_DESIGN.IS_ENABLED [get_runs impl_1]] 1 phys_opt_enabled
  require_equal [get_property STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE [get_runs impl_1]] AggressiveExplore physical_optimization
  require_equal [get_property STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE [get_runs impl_1]] NoTimingRelaxation routing
  foreach {run property relative} {
   synth_1 STEPS.SYNTH_DESIGN.TCL.PRE ip_patch/process_control/synthesis_pre.tcl
   impl_1 STEPS.INIT_DESIGN.TCL.POST ground_station_flow/formal_linked_audit.tcl
   impl_1 STEPS.OPT_DESIGN.TCL.PRE ground_station_flow/video_npu_opt_pre.tcl
   impl_1 STEPS.OPT_DESIGN.TCL.POST ground_station_flow/video_npu_opt_post.tcl
   impl_1 STEPS.PLACE_DESIGN.TCL.PRE ground_station_flow/video_pre_place.tcl
   impl_1 STEPS.ROUTE_DESIGN.TCL.POST ground_station_flow/formal_route_post.tcl
   impl_1 STEPS.WRITE_BITSTREAM.TCL.PRE ground_station_flow/formal_bitstream_guard.tcl
   impl_1 STEPS.WRITE_BITSTREAM.TCL.POST ip_patch/process_control/write_bitstream_post.tcl
  } {
   # The restricted host environment was observed to lose AppData in Tcl
   # file normalize; a normal host probe preserves it. Avoid needless rewriting.
   # Use the tool's original absolute paths; check existence without rewriting.
   set expected [file join [get_property DIRECTORY [current_project]] $relative]
   set actual [get_property $property [get_runs $run]]
   require_equal [string tolower [string map {\\ /} $actual]] [string tolower [string map {\\ /} $expected]] $run/$property
   if {![file isfile $actual]} {error "Missing registered hook: $actual"}
  }
 }
 proc normalize_value {value root} {
  return [string map [list $root {<PROJECT>} \\ / \n {\n} \r {}] $value]
 }
 proc snapshot {path} {
  set root [get_property DIRECTORY [current_project]]
  set rows {}
  lappend rows "tool\tversion\t[version -short]"
  foreach property {PART TARGET_LANGUAGE SIMULATOR_LANGUAGE DEFAULT_LIB IP_REPO_PATHS} {
   lappend rows "project\t$property\t[get_property $property [current_project]]"
  }
  foreach fs [lsort [get_filesets]] {
   foreach property [lsort [list_property $fs]] {
    if {[regexp {^(TOP|VERILOG_DEFINE|VHDL|GENERIC|INCLUDE_DIRS|FILESET_TYPE|SOURCE_SET)} $property]} {
     lappend rows "fileset:$fs\t$property\t[get_property $property $fs]"
    }
   }
  }
  foreach run [lsort [get_runs]] {
   foreach property [lsort [list_property $run]] {
    if {[regexp {^(STEPS\.|STRATEGY$|FLOW$|PART$|SRCSET$|CONSTRSET$)} $property]} {
     lappend rows "run:$run\t$property\t[get_property $property $run]"
    }
   }
  }
  foreach f [lsort [get_files -all]] {
   foreach property {FILE_TYPE LIBRARY USED_IN_SYNTHESIS USED_IN_IMPLEMENTATION USED_IN_SIMULATION PROCESSING_ORDER SCOPED_TO_REF SCOPED_TO_CELLS IS_ENABLED} {
    if {[lsearch -exact [list_property $f] $property] >= 0} {
     lappend rows "file:$f\t$property\t[get_property $property $f]"
    }
   }
  }
  foreach kind {synthesis simulation} {
   set index 0
   foreach f [get_files -compile_order sources -used_in $kind] {
    lappend rows "compile:$kind\t$index\t$f"
    incr index
   }
  }
  set normalized {}
  foreach row $rows {lappend normalized [normalize_value $row $root]}
  ::gs_formal_io::write_new $path "[join $normalized \n]\n" crlf
 }
 proc verify_controls {snapshot expected} {
  if {![file isfile $expected]} {error "Missing sealed configuration authority: $expected"}
  set actual_rows [split [::gs_formal_io::read_text $snapshot] \n]
  set selected {}
  foreach row $actual_rows {
   if {[regexp {^(tool\t|project\t|fileset:|run:)} $row]} {lappend selected $row}
  }
  set wanted [string trimright [::gs_formal_io::read_text $expected] \n]
  if {$wanted eq ""} {error "Sealed configuration authority is empty"}
  require_equal [join $selected \n] $wanted complete_project_fileset_run_configuration
 }
}
