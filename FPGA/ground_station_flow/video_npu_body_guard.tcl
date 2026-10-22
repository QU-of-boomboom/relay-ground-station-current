# Preserve the entire instantiated NPU primitive body without freezing the
# vendor EDIF's two undriven export ports. Never modify the EDIF or invent drivers.
proc video_npu_preserve {ledger} {
 set npu [get_cells -quiet U0_ps_ai_peripheral/ZGolo]
 if {[llength $npu]!=1} {error "Missing retained NPU"}
 set cells [get_cells -hier -filter {NAME =~ U0_ps_ai_peripheral/ZGolo/* && IS_PRIMITIVE == 1}]
 if {[llength $cells]<1} {error "NPU body is empty"}
 set fd [open $ledger w]
 foreach name [get_property NAME $cells] ref [get_property REF_NAME $cells] {
  puts $fd "$name\t$ref"
 }
 close $fd
 set_property DONT_TOUCH true $cells
 set_property DONT_TOUCH false $npu
 puts "NPU_BODY_PROTECTED [llength $cells] original primitives; boundary optimization enabled"
}

proc video_npu_verify {ledger output} {
 set fd [open $ledger r]
 array set expected {}
 while {[gets $fd row]>=0} {
  lassign [split $row "\t"] name ref
  if {$name eq "" || $ref eq "" || [info exists expected($name)]} {error "Invalid NPU ledger"}
  set expected($name) $ref
 }
 close $fd
 if {[array size expected]<1} {error "NPU ledger empty"}
 puts "NPU_LEDGER_LOADED [array size expected] records"
 set cells [get_cells -hier -filter {NAME =~ U0_ps_ai_peripheral/ZGolo/* && IS_PRIMITIVE == 1}]
 array set actual {}
 foreach cell $cells {
  set name [get_property NAME $cell]
  set actual($name) [get_property REF_NAME $cell]
 }
 puts "NPU_BODY_LOADED [array size actual] primitives"
 set fd [open $output w]
 set missing 0
 set changed 0
 foreach name [array names expected] {
  set ref $expected($name)
  if {![info exists actual($name)]} {
   incr missing
   puts $fd "missing=$name"
  } elseif {$actual($name) ne $ref} {
   incr changed
   puts $fd "changed=$name expected=$ref actual=$actual($name)"
  }
 }
 puts $fd "expected_primitives=[array size expected]"
 puts $fd "actual_primitives=[array size actual]"
 puts $fd "missing_primitives=$missing"
 puts $fd "changed_primitive_types=$changed"
 puts $fd "board_verified=false"
 close $fd
 if {$missing || $changed} {error "NPU primitive body changed; see $output"}
 puts "NPU_BODY_PRESERVED [array size expected] original primitives"
}

proc video_boundary_evidence {output} {
 set fd [open $output w]
 set ps [get_cells -hier -filter {REF_NAME == PS7}]
 if {[llength $ps]!=1} {error "Expected one retained PS primitive"}
 # The PS primitive has a sixth WID bit, while the vendor NPU export is five
 # bits wide. Inspect exactly the original undriven consumers, not that already
 # extended upper bit. Literal list entries prevent bracket glob expansion.
 set wanted [list {SAXIHP1WID[0]} {SAXIHP1WID[1]} {SAXIHP1WID[2]} {SAXIHP1WID[3]} {SAXIHP1WID[4]} AI_IN3642]
 set pins {}
 foreach pin [get_pins -of_objects $ps -filter {REF_PIN_NAME =~ SAXIHP1WID* || REF_PIN_NAME == AI_IN3642}] {
  if {[lsearch -exact $wanted [get_property REF_PIN_NAME $pin]]>=0} {lappend pins $pin}
 }
 puts $fd "ps_primitive=$ps consumer_count=[llength $pins]"
 if {[llength $pins]!=6} {
  puts $fd "available_relevant_pins=[get_pins -of_objects $ps -filter {NAME =~ *WID* || NAME =~ *3642*}]"
  close $fd
  error "Expected six original PS consumer pins"
 }
 foreach pin $pins {
  puts $fd "consumer=$pin"
  set nets [get_nets -of_objects $pin]
  puts $fd "nets=$nets"
  foreach driver [get_pins -quiet -leaf -of_objects $nets -filter {DIRECTION == OUT}] {
   set cell [get_cells -of_objects $driver]
   puts $fd "driver=$driver ref=[get_property REF_NAME $cell]"
  }
 }
 close $fd
}
