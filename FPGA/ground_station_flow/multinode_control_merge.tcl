# Runs AFTER the unmodified vendor opt post-hook and before placement.
# No cells, constraints, reserved sites, clocks, or platform interfaces removed.
report_control_sets -verbose -file control_sets_before_merge.rpt
opt_design -control_set_merge
report_control_sets -verbose -file control_sets_after_merge.rpt
report_utilization -hierarchical -file utilization_after_control_merge.rpt
write_checkpoint -force before_place_control_merge.dcp
