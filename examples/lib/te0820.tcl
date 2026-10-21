# te0820.tcl — block-design helpers for a Trenz TE0820-04-2BE21MA (ZU2EG) on a TE0701 carrier,
# booted from Trenz's BOOT.BIN (whose psu_init owns the real PS configuration).
namespace eval te0820 {
    variable part       xczu2eg-sfvc784-1-e
    variable board      trenz.biz:te0820_2eg_1e:part0:2.0
    variable board_repo /work/te0820-rd/board_files

    # The PS block is a stub for the PL side: board preset for coherence, pl_clk0 = 100 MHz
    # (what psu_init programs), AXI/IRQ only on request.
    #   -axi 1  enable M_AXI_HPM0_LPD, 32-bit (the only PS->PL master psu_init enabled)
    #   -irq 1  enable pl_ps_irq0 (PL -> GIC SPI 121; phase 3)
    proc ps {args} {
        array set o {-axi 0 -irq 0}
        array set o $args
        set ps [create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e zynq_ultra_ps_e_0]
        if {[get_property BOARD_PART [current_project]] ne ""} {
            if {[catch {apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e \
                            -config {apply_board_preset "1"} $ps} err]} {
                puts "PRESET: not applied ($err)"
            } else { puts "PRESET: TE0820 board preset applied" }
        }
        set_property -dict [list \
            CONFIG.PSU__FPGA_PL0_ENABLE 1 CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ 100 \
            CONFIG.PSU__USE__M_AXI_GP0 0 CONFIG.PSU__USE__M_AXI_GP1 0 CONFIG.PSU__USE__S_AXI_GP2 0 \
            CONFIG.PSU__USE__M_AXI_GP2 $o(-axi) CONFIG.PSU__MAXIGP2__DATA_WIDTH 32 \
            CONFIG.PSU__USE__IRQ0 $o(-irq)] $ps
        puts "PLCLK: pl_clk0 = [get_property CONFIG.FREQ_HZ [get_bd_pins $ps/pl_clk0]] Hz"
        return $ps
    }

    proc clk {} { return [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] }

    # An RTL module from the project sources as a BD cell; its `clk` pin (if any) gets pl_clk0.
    proc module {ref {name ""}} {
        if {$name eq ""} { set name ${ref}_0 }
        set c [create_bd_cell -type module -reference $ref $name]
        if {[llength [get_bd_pins -quiet $c/clk]]} { connect_bd_net [clk] [get_bd_pins $c/clk] }
        return $c
    }

    # Hook an AXI-Lite slave interface to HPM0_LPD at a fixed address. The automation adds the
    # SmartConnect and a proc_sys_reset (pl_resetn0) and clocks everything from pl_clk0.
    proc axi_slave {cell intf offset {range 64K}} {
        apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config [list \
            Clk_master {Auto} Clk_slave {Auto} Clk_xbar {Auto} \
            Master "/zynq_ultra_ps_e_0/M_AXI_HPM0_LPD" Slave "/$cell/$intf" \
            ddr_seg {Auto} intc_ip {New AXI SmartConnect} master_apm {0}] \
            [get_bd_intf_pins $cell/$intf]
        set seg [get_bd_addr_segs -of_objects [get_bd_addr_spaces zynq_ultra_ps_e_0/Data] \
                     -filter "NAME =~ SEG_${cell}_*"]
        set_property offset $offset $seg
        set_property range  $range  $seg
        return $seg
    }

    # AXI GPIO, all outputs, default 0, at `offset`. Extra CONFIG.* pairs may follow.
    proc axi_gpio {name width offset args} {
        set g [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio $name]
        set_property -dict [concat [list CONFIG.C_GPIO_WIDTH $width CONFIG.C_ALL_OUTPUTS 1 \
                                        CONFIG.C_DOUT_DEFAULT 0x00000000] $args] $g
        axi_slave $name S_AXI $offset
        return $g
    }

    # Expose a cell pin as a top-level port with a chosen name (constrain it in the XDC).
    proc external {pin name} {
        make_bd_pins_external [get_bd_pins $pin]
        set_property NAME $name [get_bd_ports [file tail $pin]_0]
    }

    # Phase 3: route a PL interrupt line into the PS (needs `ps -irq 1`).
    proc irq {pin} {
        connect_bd_net [get_bd_pins $pin] [get_bd_pins zynq_ultra_ps_e_0/pl_ps_irq0]
    }
}
