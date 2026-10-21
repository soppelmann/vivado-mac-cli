# Scripted Vivado projects

Vivado projects are hundreds of generated files with absolute paths baked in; block designs
are only reproducible from Tcl. These examples keep each design as a handful of source files
plus a short `project.tcl`, and regenerate everything else. They are plain Vivado Tcl — nothing
here is specific to vivado-mac except the `/work/...` paths (the shared work dir as the VM sees it).

```
examples/
├── lib/vmk.tcl          the build flow every project uses
├── lib/te0820.tcl       board helpers for a Trenz TE0820 (Zynq UltraScale+ ZU2EG) on a TE0701 carrier
├── template/            copy this to start a new project
│   ├── project.tcl      the design: file list + a `design_bd` procedure made of helper calls
│   ├── top.sv           your RTL (module `top`)
│   ├── pins.xdc         pin constraints
│   └── sw/              a FreeBSD/Linux user program that talks to the design (axi.h, example.c, Makefile)
└── te0820/
    ├── phase1/          PS stub + button-flashes-LED on Pmod J5
    └── phase2/          phase 1 + an AXI GPIO at 0x8000_0000, driven from the OS (sw/axiled.c)
```

## Install into the work dir

```bash
cp -r examples/lib examples/template ~/vivado-work/
cp -r examples/te0820/phase1 examples/te0820/phase2 ~/vivado-work/    # optional
```

The scripts `source /work/lib/vmk.tcl`, so `lib/` must sit at the top of the work dir.

## Build a project

```bash
vivado-mac vivado -mode batch -source phase2/project.tcl
```

About 6 minutes for these designs. The run prints a few tagged lines and ends with
`VMK_OK <name> part=… bit=… bin=…`:

| Line | Meaning |
|---|---|
| `BOARD: …` | the board part was accepted (or `not applied`, in which case the plain part is used) |
| `PRESET: …` | the board's PS preset was applied to the Zynq PS block |
| `PLCLK: pl_clk0 = … Hz` | the PL clock the design is built for |
| `ADDR: … offset=… range=…` | the PS address map: where each AXI slave is reachable from software |
| `BUILD: launch_runs -> …` | the project-mode runs' final status |

Outputs land next to the sources: `<bd>_wrapper.bit`, `<bd>_wrapper.bin` (header-less, what a
Linux/FreeBSD FPGA manager takes), `util.rpt`, `timing.rpt`, `io.rpt`. Everything under
`<project>/vivado/` is generated and disposable.

## `lib/vmk.tcl` — the flow

A project file fills the `::design` array, defines `proc design_bd {}` and calls `vmk::build`,
which does, in order:

1. `create_project` for `design(part)` under `<dir>/vivado`, `-force` (the previous generated
   project is discarded); sets `board_part` if `design(board)` is given, after adding
   `design(board_repo)` to Vivado's board search path.
2. Adds `design(sources)` and `design(constraints)` (paths relative to `design(dir)`).
3. `create_bd_design design(bd)`, calls your `design_bd`, validates and saves it, prints the
   `ADDR:` lines from the PS's address map.
4. Generates the HDL wrapper and makes it the top.
5. Builds with project-mode runs (`launch_runs impl_1 -to_step write_bitstream`, `-bin_file` on).
   This is the child-process path; it is verified working under Rosetta on Vivado 2026.1. If it
   fails, the in-process flow (`synth_design`, `opt_design`, `place_design`, `route_design`,
   `write_bitstream`) runs instead.
6. Copies the bitstreams next to the sources and writes the three reports.

`::design` keys: `dir` (project dir as the VM sees it), `name`, `part`, `bd` (block-design name;
the top is `<bd>_wrapper`), `sources`, `constraints`, optional `board` and `board_repo`.

One Vivado quirk the file works around, worth knowing if you script runs yourself: `launch_runs`
and `wait_on_run` are Tcl and leak variables such as `dir` into the calling procedure's frame
(and move the working directory). `vmk::build` re-reads its paths from `::design` after the runs.

## `lib/te0820.tcl` — board helpers

Everything the TE0820/TE0701 investigation produced, as procedures you call from `design_bd`:

| Call | What it does |
|---|---|
| `te0820::ps ?-axi 0/1? ?-irq 0/1?` | Adds the Zynq UltraScale+ PS block with the board preset. It is a **stub**: on a board booted from a BOOT.BIN, the first-stage boot loader's `psu_init` owns the real PS configuration; the PL only needs `pl_clk0` (100 MHz here) and, on request, the `M_AXI_HPM0_LPD` master at 32 bits (`-axi 1`) and `pl_ps_irq0` (`-irq 1`). Those two values match what Trenz's `psu_init` programs; keep them unless you build your own boot image. |
| `te0820::clk` | The `pl_clk0` pin, for connecting your own clocked blocks. |
| `te0820::module REF ?NAME?` | Your RTL module (from `design(sources)`) as a block-design cell; a `clk` pin is wired to `pl_clk0`. |
| `te0820::axi_slave CELL INTF OFFSET ?RANGE?` | Hooks an AXI-Lite slave to HPM0_LPD at a fixed address. The designer automation adds the SmartConnect and a `proc_sys_reset` on `pl_resetn0`. |
| `te0820::axi_gpio NAME WIDTH OFFSET ?CONFIG…?` | An all-outputs AXI GPIO at `OFFSET` (register 0 = data). |
| `te0820::external PIN NAME` | Makes a cell pin a top-level port named `NAME`; constrain it in the XDC. |
| `te0820::irq PIN` | Connects a PL interrupt line to the PS (`pl_ps_irq0`, GIC SPI 121). Needs `ps -irq 1`. |

Variables: `te0820::part` (`xczu2eg-sfvc784-1-e`), `te0820::board`
(`trenz.biz:te0820_2eg_1e:part0:2.0`), `te0820::board_repo` (`/work/te0820-rd/board_files`, the
`board_files` folder of Trenz's reference design zip, unpacked into the work dir). For another
module variant change `part`/`board`; for another board, write a sibling file with the same shape.

## `template/` — a new project

```bash
cd ~/vivado-work && cp -r lib/template myproj && sed -i '' 's/NAME/myproj/g' myproj/project.tcl myproj/pins.xdc
```

Then edit `top.sv`, `pins.xdc` and the `design_bd` body in `project.tcl`, and build. The
template's `design_bd` shows, commented out, how to add registers (`axi_gpio`/`axi_slave`), an
interrupt (`irq`) and external pins.

`template/sw/` is the software side: `axi.h` maps one page of `/dev/mem` at an address from the
`ADDR:` lines and offers `axi_rd`/`axi_wr` by register offset; `example.c` reads/writes an AXI
GPIO; the `Makefile` builds on the board (`make`) or cross-compiles on the Mac (`make cross`,
pointing at a FreeBSD source tree's bootstrapped toolchain via `OBJ=`). Read the warning in
`axi.h`: an AXI access with no slave behind the address hangs the CPU — load the bitstream first.

## `te0820/phase1`, `te0820/phase2` — worked examples

Both target a Trenz TE0820-04-2BE21MA (ZU2EG) on a TE0701 carrier and use Pmod **J5**, the only
header there whose pins reach the PL. The carrier's own LEDs and buttons sit on its system
controller CPLD, so these need an LED (through ~100 Ω) and a push button on J5. J5 is in bank 65,
an HP bank: the carrier's VIOTA rail must be **1.8 V** (`LVCMOS18`); the J5 pin table with the
derivation (carrier TRM → B2B connector → module schematic) is in `pmod_j5.xdc`.

- **phase1**: `te0820::ps` + `hello.sv`; holding the button flashes the LED at 2 Hz.
- **phase2**: adds `te0820::ps -axi 1` and `te0820::axi_gpio axi_gpio_0 1 0x80000000`; GPIO bit 0
  forces the LED on. `sw/axiled` (`on|off|blink [ms]|read [addr]`) drives it from FreeBSD via
  `/dev/mem`, and `axiled read` works against any AXI slave at that address.
