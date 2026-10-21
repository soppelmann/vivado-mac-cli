# phase1 — PS stub (pl_clk0 only) + hello.sv: button on Pmod J5.3 flashes the LED on J5.1.
#   vivado-mac vivado -mode batch -source phase1/project.tcl
source /work/lib/vmk.tcl
source /work/lib/te0820.tcl
array set design [list \
    dir /work/phase1  name phase1  bd sys \
    part $te0820::part  board $te0820::board  board_repo $te0820::board_repo \
    sources {hello.sv}  constraints {pmod_j5.xdc}]

proc design_bd {} {
    te0820::ps
    set h [te0820::module hello]
    te0820::external $h/btn btn
    te0820::external $h/led led
}
vmk::build
