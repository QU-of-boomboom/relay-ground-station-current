# Keep the verified official route ECO first, then collect complete diagnostics.
set gs_route_flow [file dirname [info script]]
source [file join [file dirname $gs_route_flow] ip_patch process_control implementation_route_post.tcl]
source [file join $gs_route_flow formal_route_reports.tcl]
