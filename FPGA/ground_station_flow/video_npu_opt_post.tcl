set video_flow_dir [file dirname [info script]]
set video_project_dir [file dirname $video_flow_dir]
source [file join $video_project_dir ip_patch process_control implementation_opt_post.tcl]
source [file join $video_flow_dir video_npu_body_guard.tcl]
video_npu_verify [file join [pwd] npu_body_before_opt.tsv] [file join [pwd] npu_body_after_opt.txt]
report_drc -checks [get_drc_checks NDRV-1] -file npu_boundary_driverless.rpt
if {[llength [get_drc_violations -quiet]]} {error "Driverless net remains after original vendor OPT hook"}
video_boundary_evidence [file join [pwd] npu_boundary_consumers.txt]
