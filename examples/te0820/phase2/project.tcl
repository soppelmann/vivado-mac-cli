# phase2 — phase 1 + a dual-channel AXI GPIO on the PS's HPM0_LPD port at 0x8000_0000:
# ch1 bit 0 (reg 0x00) forces the LED on, ch2 (reg 0x08) reads a free-running PL counter, so
# FreeBSD can both drive and observe the fabric through /dev/mem (sw/axiled.c) with no parts attached.
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
    # channel 1: 1 output bit -> force_on (reg 0x00); channel 2: 32 input bits <- tick (reg 0x08)
    set g [te0820::axi_gpio axi_gpio_0 1 0x80000000 \
               CONFIG.C_IS_DUAL 1 CONFIG.C_GPIO2_WIDTH 32 CONFIG.C_ALL_INPUTS_2 1]
    connect_bd_net [get_bd_pins $g/gpio_io_o]  [get_bd_pins $h/force_on]
    connect_bd_net [get_bd_pins $g/gpio2_io_i] [get_bd_pins $h/tick]
    te0820::external $h/btn btn
    te0820::external $h/led led
}
vmk::build
