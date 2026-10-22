# Retained Lite-board PL pins. Source: JFMQL30TAI_LITE(1).pdf,
# physical pages 9 (bank 12 / PS JTAG) and 10 (banks 33/34).
# These are pin/electrical assignments only: no timing exceptions or DRC waiver.
set_property PACKAGE_PIN J1 [get_ports {led[0]}]
set_property PACKAGE_PIN M6 [get_ports {led[1]}]
set_property PACKAGE_PIN F8 [get_ports sys_rst]
set_property IOSTANDARD LVCMOS15 [get_ports {led[0] led[1] sys_rst}]

set_property PACKAGE_PIN AB15 [get_ports PJTAG_TCK]
set_property PACKAGE_PIN AB14 [get_ports PJTAG_TMS]
set_property PACKAGE_PIN AD15 [get_ports PJTAG_TDI]
set_property PACKAGE_PIN AD16 [get_ports PJTAG_TDO]
set_property IOSTANDARD LVCMOS33 [get_ports {PJTAG_TCK PJTAG_TMS PJTAG_TDI PJTAG_TDO}]
