# The preserved current-source checkpoint is read only; no baseline edits.
proc video_primitive_counts {pattern output} {
 set counts [dict create]
 foreach cell [get_cells -hier -filter "NAME =~ $pattern && IS_PRIMITIVE == 1"] {
  dict incr counts [get_property REF_NAME $cell]
 }
 set fd [open $output w]
 foreach ref [lsort [dict keys $counts]] {puts $fd "$ref\t[dict get $counts $ref]"}
 close $fd
 return $counts
}

proc video_trim_audit {{check_project_top 1}} {
 # NAME is a session handle (design_1/checkpoint_*), not the HDL top.
 if {[get_property TOP [current_design]] ne "ai7030_edif_top"} {error "Incorrect netlist top"}
 # The formal INIT hook separately checks the real parent XPR before returning
 # to the GateLvl worker; the linked design TOP remains mandatory below.
 if {$check_project_top && [get_property TOP [get_filesets sources_1]] ne "ai7030_edif_top"} {error "Incorrect project top"}
 set audit [open video_synthesis_audit.txt w]
 puts $audit "top=[get_property TOP [current_design]]"
 puts $audit "design_object=[get_property NAME [current_design]]"
 set boxes [get_cells -hier -filter {IS_BLACKBOX == 1}]
 puts $audit "blackboxes=[llength $boxes]"
 if {[llength $boxes]} {error "Unresolved synthesis blackbox"}
 foreach required {U_gs_station U0_ps_ai_peripheral/ZGolo U0_ps_ai_peripheral/mig_ddr3_u0 U0_ps_ai_peripheral/ps_ai_wrapper_u0 U0_ps_ai_peripheral/U_platform_control} {
  set cells [get_cells -quiet $required]
  puts $audit "$required count=[llength $cells]"
  if {[llength $cells]!=1} {error "Required hierarchy lost: $required"}
 }
 foreach removed {rx_sdi_inst U0_ps_ai_peripheral/frame_to_ps_inst0 U0_ps_ai_peripheral/frame_trans_inst0 U0_ps_ai_peripheral/u_vtc U_adder_top} {
  set cells [get_cells -quiet $removed]
  puts $audit "$removed count=[llength $cells]"
  if {[llength $cells]} {error "Retired hierarchy remains: $removed"}
 }
 foreach pattern {HDMI_* FMC_HPC_* rx_gtx_full_reset} {
  set ports [get_ports -quiet $pattern]
  puts $audit "retired_port/$pattern count=[llength $ports]"
  if {[llength $ports]} {error "Retired dedicated ports remain"}
 }
 foreach ip {sys_clk mgtclk smpte_sdi cmos_clkgen_742_5 afifo_16i_64o_largebuf afifo_64i_16o_128 afifo_24w_4096d fifo_1 windex_buf_2b_16w rindex_buf_2b_16w} {
  if {[llength [get_ips -quiet $ip]]} {error "Retired IP remains in project: $ip"}
 }
 # MIG also uses OSERDESE2. Preserve those shared DDR serializers.
 foreach ref {GTXE2_CHANNEL GTXE2_COMMON IBUFDS_GTE2} {
  set cells [get_cells -hier -filter "REF_NAME == $ref"]
  puts $audit "$ref count=[llength $cells]"
  if {[llength $cells]} {error "Video-only primitive remains: $ref"}
 }
 set protect [get_property DONT_TOUCH [get_cells U0_ps_ai_peripheral/ZGolo]]
 puts $audit "npu_dont_touch=$protect"
 if {$protect ne "1" && $protect ne "true" && $protect ne "TRUE"} {error "NPU protection missing"}
 video_primitive_counts * candidate_synthesis_primitives.tsv
 set now [video_primitive_counts U0_ps_ai_peripheral/ZGolo/* candidate_npu_primitives.tsv]
 # The fixed NPU and its functional dependency body must not shrink just
 # because the retired camera no longer supplies image transactions.
 set fd [open baseline_npu_primitives.tsv r]
 while {[gets $fd row]>=0} {
  lassign [split $row "\t"] ref count
  set actual 0
  if {[dict exists $now $ref]} {set actual [dict get $now $ref]}
  puts $audit "npu/$ref baseline=$count candidate=$actual"
  if {$actual < $count} {error "NPU primitive category shrank: $ref $count -> $actual"}
 }
 close $fd
 puts $audit "synthesis_structure_passed=true"
 puts $audit "implementation_passed=false"
 puts $audit "board_verified=false"
 close $audit
 report_clock_utilization -file candidate_clock_utilization.rpt
}
