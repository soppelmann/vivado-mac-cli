# NAME — one line on what this design does.
#   vivado-mac vivado -mode batch -source NAME/project.tcl
source /work/lib/vmk.tcl
source /work/lib/te0820.tcl
array set design [list \
    dir /work/NAME  name NAME  bd sys \
    part $te0820::part  board $te0820::board  board_repo $te0820::board_repo \
    sources {top.sv}  constraints {pins.xdc}]

proc design_bd {} {
    # PS stub. Add -axi 1 for PS->PL registers on HPM0_LPD, -irq 1 for PL->PS interrupts.
    te0820::ps
    # Your RTL as a block; its clk pin gets pl_clk0 (100 MHz).
    set t [te0820::module top]
    # Registers reachable from FreeBSD (needs -axi 1):
    #   set g [te0820::axi_gpio axi_gpio_0 8 0x80000000]        ;# 8 output bits at 0x8000_0000
    #   te0820::axi_slave my_regs S_AXI 0x80010000              ;# your own AXI-Lite block
    # Interrupt into the PS (needs -irq 1):  te0820::irq $t/irq
    # Pins: make module pins top-level ports, then constrain them in pins.xdc.
    te0820::external $t/led led
}
vmk::build
