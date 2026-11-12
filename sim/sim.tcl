# sim.tcl : roda a simulação do vídeo do cartão SD (tbVideo) no simulador do Vivado, sem abrir a interface.
# Como rodar (na pasta ProjetoAelSistemas):
#     vivado -mode batch -source sim/sim.tcl
# No fim aparece "PASSOU" ou "FALHOU". Leva alguns minutos (simula ~0,5 s de placa).

set root [file normalize [file dirname [info script]]/..]
cd $root
set simDir $root/build_sim
file delete -force $simDir

create_project simVideo $simDir -part xc7a100tcsg324-1
add_files -fileset sim_1 -norecurse [concat \
    vga/vgaTiming.sv \
    [glob video/*.sv] \
    [glob sim/*.sv] ]
set_property file_type SystemVerilog [get_files -of_objects [get_filesets sim_1] *.sv]
set_property top tbVideo [get_filesets sim_1]
set_property -name {xsim.simulate.runtime} -value {all} -objects [get_filesets sim_1]

launch_simulation
close_sim
