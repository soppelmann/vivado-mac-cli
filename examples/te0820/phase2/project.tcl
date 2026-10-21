# phase2 — phase 1 + an AXI GPIO on the PS's HPM0_LPD port at 0x8000_0000; bit 0 forces the LED
# on, so FreeBSD can drive it through /dev/mem (sw/axiled.c).
#   vivado-mac vivado -mode batch -source phase2/project.tcl
source /work/lib/vmk.tcl
source /work/lib/te0820.tcl
array set design [list \
    dir /work/phase2  name phase2  bd sys \
    part $te0820::part  board $te0820::board  board_repo $te0820::board_repo \
    sources {hello.sv}  constraints {pmod_j5.xdc}]

proc design_bd {} {
    te0820::ps -axi 1
    set h [te0820::module hello]
    set g [te0820::axi_gpio axi_gpio_0 1 0x80000000]
    connect_bd_net [get_bd_pins $g/gpio_io_o] [get_bd_pins $h/force_on]
    te0820::external $h/btn btn
    te0820::external $h/led led
}
vmk::build
