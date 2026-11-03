# build.tcl : cria o projeto, sintetiza, implementa e gera o bitstream. Sem abrir a interface do Vivado.
# Como rodar (na pasta ProjetoAelSistemas):
#     vivado -mode batch -source build.tcl
# Segue o roteiro dos slides: create_project -> add_files -> launch_runs synth_1 / impl_1 -> write_bitstream.

# ---------- Ajustes ----------
set topName  hudTop;# módulo de cima (nome do module em hudTop.sv)
set partName xc7a100tcsg324-1;# FPGA da Nexys A7-100T
set projName hud;# nome do projeto

# Para o outro topo: vivado -mode batch -source build.tcl -tclargs xadcTestTop
if {$argc > 0} { set topName [lindex $argv 0] }
set jobs 4;# quantos núcleos do PC usar

# ---------- Pastas (relativas a este arquivo) ----------
set root [file dirname [file normalize [info script]]]
set buildDir $root/build

# Começa sempre do zero, para não sobrar lixo de uma síntese antiga
file delete -force $buildDir
file mkdir $buildDir

# ---------- 1) Criar projeto ----------
create_project $projName $buildDir -part $partName

# ---------- 2) Adicionar fontes: todos os .sv das pastas do projeto ----------
# O Vivado se perde com ESPAÇOS no caminho
# Por isso entramos na pasta do projeto e usamos caminhos RELATIVOS (vga/arquivo.sv), que não têm espaço.
cd $root

set srcFiles [concat \
    [glob -nocomplain vga/*.sv] \
    [glob -nocomplain drawings/*.sv] \
    [glob -nocomplain sensors/SPI/*.sv] \
    [glob -nocomplain sensors/I2C/*.sv] \
    [glob -nocomplain sensors/XADC/*.sv] \
    [glob -nocomplain top/*.sv] ]

foreach f $srcFiles {
    add_files -norecurse $f
}
set_property file_type SystemVerilog [get_files -of_objects [get_filesets sources_1] *.sv]
set_property top $topName [get_filesets sources_1]

# Constraints (pinos)
add_files -fileset constrs_1 -norecurse xdc/nexysA7_$topName.xdc

# IPs (ex.: XADC Wizard): copia o .xci de ip/ para dentro do projeto e gera os arquivos do IP
foreach f [glob -nocomplain ip/*/*.xci] {
    import_files -norecurse $f
}
if {[llength [get_files -quiet *.xci]] > 0} {
    generate_target all [get_files *.xci]
}

# ---------- 3) Síntese ----------
launch_runs synth_1 -jobs $jobs
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
    puts "ERRO: a sintese falhou. Veja $buildDir/$projName.runs/synth_1/runme.log"
    exit 1
}

# Relatórios da SÍNTESE (antes do place&route): utilização por módulo, timing estimado, warnings
file mkdir $buildDir/reports
open_run synth_1
report_utilization -hierarchical -file $buildDir/reports/synth_util.rpt;# LUTs, FFs, BRAM, DSP por módulo
report_timing_summary -file $buildDir/reports/synth_timing.rpt;# WNS/TNS estimado 
report_power -file $buildDir/reports/synth_power.rpt
# Warnings críticos (latch inferido, multi-driven) ficam no log da síntese:
file copy -force $buildDir/$projName.runs/synth_1/runme.log $buildDir/reports/synth_log.txt
close_design

# ---------- 4) Implementação + bitstream ----------
launch_runs impl_1 -to_step write_bitstream -jobs $jobs
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
    puts "ERRO: a implementacao falhou. Veja $buildDir/$projName.runs/impl_1/runme.log"
    exit 1
}

# ---------- 5) Relatórios  ----------
open_run impl_1
report_utilization    -file $buildDir/reports/util.rpt;# uso de LUTs, FFs, BRAM, DSP
report_timing_summary -file $buildDir/reports/timing.rpt;# timing final: WNS/TNS (negativo = nao fechou)
report_power          -file $buildDir/reports/power.rpt;# estimativa de potencia

# Copia o .bit para a pasta do projeto, fácil de achar
file copy -force $buildDir/$projName.runs/impl_1/$topName.bit $root/$topName.bit
puts "PRONTO: $root/$topName.bit"
puts "RELATORIOS em: $buildDir/reports"
