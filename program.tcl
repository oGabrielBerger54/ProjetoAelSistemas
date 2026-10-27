# Antes: ligue a Nexys A7 no USB e ligue a chave de energia.
# Como rodar (na pasta ProjetoAelSistemas):
#     vivado -mode batch -source program.tcl

set root [file dirname [file normalize [info script]]]
set bitFile $root/hudTop.bit        ;# gerado pelo build.tcl

open_hw_manager
connect_hw_server -url localhost:3121;
puts [get_hw_targets];

open_hw_target [lindex [get_hw_targets] 0]

set dev [lindex [get_hw_devices] 0];
current_hw_device $dev
set_property PROGRAM.FILE $bitFile $dev
program_hw_devices $dev
refresh_hw_device $dev
puts "STATUS: DONE=[get_property REGISTER.IR.BIT5_DONE $dev]  (1 = programou)"

close_hw_target
disconnect_hw_server
close_hw_manager
