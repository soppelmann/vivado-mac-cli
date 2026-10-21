# vmk.tcl — generic "project from script" flow for designs built with vivado-mac.
#
# A project file (<dir>/project.tcl) sources this, fills the ::design array, defines
# `proc design_bd {}` (the block-design body) and calls vmk::build. Everything under
# <dir>/vivado is generated and disposable; the .tcl/.sv/.xdc files next to it are the source.
#
#   vivado-mac vivado -mode batch -source phase2/project.tcl      (paths are /work/... in the VM)
#
# ::design keys: dir name part [board board_repo] bd sources constraints
namespace eval vmk {
    proc need {key} {
        if {![info exists ::design($key)]} { error "design($key) is not set" }
        return $::design($key)
    }

    proc build {} {
        set dir  [need dir]
        set name [need name]
        set part [need part]
        set bd   [need bd]
        set top  ${bd}_wrapper

        if {[info exists ::design(board_repo)]} { set_param board.repoPaths $::design(board_repo) }
        create_project $name $dir/vivado -part $part -force
        if {[info exists ::design(board)]} {
            if {[catch {set_property board_part $::design(board) [current_project]} err]} {
                puts "BOARD: not applied ($err) -- continuing with the plain part"
            } else {
                puts "BOARD: $::design(board)"
            }
        }
        set_property target_language Verilog [current_project]
        foreach f [need sources]     { add_files -norecurse $dir/$f }
        foreach f [need constraints] { add_files -fileset constrs_1 -norecurse $dir/$f }
        update_compile_order -fileset sources_1

        create_bd_design $bd
        ::design_bd
        validate_bd_design
        save_bd_design
        foreach ps [get_bd_cells -quiet -filter {VLNV =~ xilinx.com:ip:zynq_ultra_ps_e:*}] {
            foreach seg [get_bd_addr_segs -quiet -of_objects $ps] {
                puts "ADDR: $seg offset=[get_property OFFSET $seg] range=[get_property RANGE $seg]"
            }
        }
        make_wrapper -files [get_files $bd.bd] -top -import
        set_property top $top [current_fileset]
        update_compile_order -fileset sources_1

        # Project-mode runs (child processes) — verified working under Rosetta on Vivado 2026.1;
        # the in-process flow stays as a fallback.
        set_property STEPS.WRITE_BITSTREAM.ARGS.BIN_FILE true [get_runs impl_1]
        set ok 0
        if {![catch {launch_runs impl_1 -to_step write_bitstream -jobs 4; wait_on_run impl_1} err]} {
            set status [get_property STATUS [get_runs impl_1]]
            puts "BUILD: launch_runs -> $status"
            if {[string match "*write_bitstream Complete*" $status]} { set ok 1 }
        } else {
            puts "BUILD: launch_runs failed: $err"
        }
        # Vivado's launch_runs/wait_on_run are Tcl and leak variables (dir, name, ...) into the
        # caller's frame, so re-derive every path from ::design here instead of trusting locals.
        set dir  [need dir]
        set name [need name]
        set top  [need bd]_wrapper
        if {$ok} {
            file copy -force $dir/vivado/$name.runs/impl_1/$top.bit $dir/$top.bit
            file copy -force $dir/vivado/$name.runs/impl_1/$top.bin $dir/$top.bin
            open_run impl_1
        } else {
            puts "BUILD: in-process fallback"
            reset_run synth_1
            generate_target all [get_files $bd.bd]
            synth_design -top $top
            opt_design
            place_design
            route_design
            write_bitstream -force -bin_file $dir/$top.bit
        }
        report_utilization    -file $dir/util.rpt
        report_timing_summary -file $dir/timing.rpt
        report_io             -file $dir/io.rpt
        puts "VMK_OK $name part=$part bit=$dir/$top.bit bin=$dir/$top.bin launch_runs=$ok"
    }
}
