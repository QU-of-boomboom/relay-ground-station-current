# Vivado 2018.3 XDC: only supported constraint/query commands, no if/foreach.
# Original platform register crossings retain historical GP/HP exceptions.
set gs_gp [get_clocks clk_out1_clk_wiz_0]
set gs_hp [get_clocks clk_pll_i]
set gs_old_gp [filter [all_registers -clock $gs_gp] {NAME !~ U_gs_station/* && NAME !~ U_gs_router/* && NAME !~ gs_gp_release*}]
set gs_old_hp [filter [all_registers -clock $gs_hp] {NAME !~ U_gs_station/* && NAME !~ U_gs_router/* && NAME !~ gs_gp_release*}]
set_false_path -from $gs_old_gp -to $gs_old_hp
set_false_path -from $gs_old_hp -to $gs_old_gp
# New register CDC: first synchronizer D pins only; no blanket new GP/HP exception.
set_false_path -to [get_pins -hier -regexp {U_gs_station/Bridge_Inst/.*(req_sync_reg|ack_sync_reg)\[0\]/D}]
set_false_path -to [get_pins -hier -regexp {U_gs_station/ResetNotice_Inst/notice_sync_reg\[0\]/D}]
# Raw reset synchronizer asynchronous assertion pins; downstream local release timing stays analyzed.
set_false_path -to [get_pins -hier -regexp {U_gs_station/Release_Inst/reg_(src_local|src_peer|dst_local|dst_peer)_reg\[[01]\]/CLR}]
set_false_path -to [get_pins -hier -regexp {U_gs_station/reg_ps_release_reg\[[01]\]/CLR}]
set_false_path -to [get_pins -hier -regexp {U_gs_station/ResetNotice_Inst/notice_(sync|release)_reg\[[01]\]/CLR}]
set_max_delay -datapath_only 5.0 -from [get_cells -hier -filter {NAME =~ U_gs_station/Bridge_Inst/Command_Inst/payload_reg*}] -to [get_cells -hier -filter {NAME =~ U_gs_station/Bridge_Inst/Command_Inst/dst_data_reg*}]
set_bus_skew 5.0 -from [get_cells -hier -filter {NAME =~ U_gs_station/Bridge_Inst/Command_Inst/payload_reg*}] -to [get_cells -hier -filter {NAME =~ U_gs_station/Bridge_Inst/Command_Inst/dst_data_reg*}]
set_max_delay -datapath_only 10.0 -from [get_cells -hier -filter {NAME =~ U_gs_station/Bridge_Inst/Response_Inst/payload_reg*}] -to [get_cells -hier -filter {NAME =~ U_gs_station/Bridge_Inst/Response_Inst/dst_data_reg*}]
set_bus_skew 10.0 -from [get_cells -hier -filter {NAME =~ U_gs_station/Bridge_Inst/Response_Inst/payload_reg*}] -to [get_cells -hier -filter {NAME =~ U_gs_station/Bridge_Inst/Response_Inst/dst_data_reg*}]
