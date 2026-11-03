# program.tcl : grava o .bit na FPGA pelo Hardware Manager (BÔNUS dos slides). Sem abrir a interface.
# Antes: ligue a Nexys A7 no USB e ligue a chave de energia.
# Como rodar (na pasta ProjetoAelSistemas):
#     vivado -mode batch -source program.tcl

set root [file dirname [file normalize [info script]]]
set topName hudTop;# ou: vivado -mode batch -source program.tcl -tclargs xadcTestTop
if {$argc > 0} { set topName [lindex $argv 0] }
set bitFile $root/$topName.bit;# gerado pelo build.tcl

open_hw_manager
connect_hw_server -url localhost:3121;# no modo batch o Vivado liga o servidor sozinho
puts [get_hw_targets];# lista as placas encontradas

open_hw_target [lindex [get_hw_targets] 0]

set dev [lindex [get_hw_devices] 0];# xc7a100t_0
current_hw_device $dev
set_property PROGRAM.FILE $bitFile $dev
program_hw_devices $dev
refresh_hw_device $dev
puts "STATUS: DONE=[get_property REGISTER.IR.BIT5_DONE $dev]  (1 = programou)"

close_hw_target
disconnect_hw_server
close_hw_manager
