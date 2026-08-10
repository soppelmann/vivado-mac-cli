# vivado-mac-cli

Run AMD **Vivado 2026.1 natively-ish on Apple Silicon Macs** — headless (CLI only), no Docker, no Lima, no XQuartz. [日本語 README](README.ja.md)

A zero-dependency Swift CLI (`vivado-mac`) drives Apple's **Virtualization.framework** directly: it boots an Ubuntu 24.04 ARM64 VM, injects **Rosetta 2** into it, and runs the x86-64 Linux Vivado at near-native speed over SSH.

**Verified end-to-end** (M4 Mac, macOS 26.5, 2026-08): full `synth_design → opt_design → place_design → route_design → write_bitstream` flow producing a working bitstream for an Artix-7 (xc7a35t), using the free BASIC-tier license.

```
Mac (Apple Silicon)
└─ vivado-mac (Swift CLI, zero deps, ad-hoc signed)
   └─ Virtualization.framework VM: Ubuntu 24.04 ARM64
      ├─ Rosetta 2 (VZLinuxRosettaDirectoryShare + binfmt_misc) ← x86-64 AOT translation
      ├─ Vivado 2026.1 (x86-64) at /opt/Xilinx (on the VM disk)
      └─ /work ⇄ ~/vivado-work on the Mac (virtiofs)
```

The VM is **not resident**: it auto-boots when you run a command (~30 s) and powers itself off after 15 idle minutes (configurable, `--idle 0` = stay up). A running command always keeps it alive.

## Requirements

- Apple Silicon Mac, macOS 13+ (macOS 15+ recommended — Rosetta 2 gained AVX2 there)
- Xcode Command Line Tools (`swift`). No Homebrew, no Docker
- ~120 GB free disk (7-series device set), 16 GB+ RAM recommended
- An AMD account (for the installer download and the free license)

## Install

```bash
make build
sudo make install     # /usr/local/bin/vivado-mac
vivado-mac setup      # create + provision the VM (one-time, a few minutes)
```

`setup` downloads the Ubuntu cloud image (SHA256-verified), converts qcow2→raw with a built-in stdlib-only converter, provisions via cloud-init (amd64 multiarch, Rosetta binfmt, all workarounds below), and smoke-tests that x86-64 dynamically linked binaries actually execute.

Then download the Vivado web installer (`FPGAs_AdaptiveSoCs_Unified_SDI_*_Lin64.bin`, AMD login required) from [AMD's download page](https://www.amd.com/en/support/downloads/adaptive-socs-and-fpgas/development-tools.html) and:

```bash
vivado-mac install    # finds the installer in ~/Downloads automatically
```

Interactive AMD token auth → edition pick (choose Vivado) → EULA confirm → ~22 GB download + install.

## Licensing (changed in 2026.1)

Vivado 2026.1 requires a license even for basic use. The free **BASIC tier** (all 7-series devices) is node-locked to a MAC address — and `vivado-mac` pins the VM's MAC permanently, so:

1. `vivado-mac status` → note the VM MAC
2. Generate a free BASIC license at https://www.xilinx.com/getlicense for that MAC
3. Save it as `~/vivado-work/Xilinx.lic` — done (`XILINXD_LICENSE_FILE` is pre-wired)

`vivado-mac destroy` regenerates the MAC → you'd need to re-host the license (AMD allows once a year). Don't destroy casually.

## Usage

```bash
vivado-mac vivado -mode batch -source build.tcl   # cwd is /work (= ~/vivado-work)
vivado-mac vivado -mode tcl                       # interactive Tcl
vivado-mac run make -j8                           # any guest command (argv form)
vivado-mac run 'ls *.bit && df -h /'              # single arg = shell string
vivado-mac shell                                  # SSH into the guest
vivado-mac start / stop / status / doctor / version
```

**Use in-process Tcl, not `launch_runs`** — child-process spawning is the one flaky path under Rosetta:

```tcl
read_verilog /work/proj/top.v
read_xdc /work/proj/top.xdc
synth_design -top top -part xc7a35tcpg236-1
opt_design
place_design
route_design
write_bitstream -force /work/proj/top.bit
```

## The Rosetta workaround catalog

Everything below was hit, root-caused, and fixed live on real hardware. The tool applies all of it automatically — listed here because it's the actual hard-won knowledge of running Vivado 2026.1 under Rosetta, and none of it was previously documented anywhere:

| Problem | Root cause → fix |
|---|---|
| `xsetup` dies: "not supported on 32 bit platforms" | Installer scripts run under ARM bash, `uname -m` = aarch64 → a `uname`/`arch` shim (`/opt/vivado-shim`) reports x86_64, scoped via PATH |
| Installer's Java can't spawn `/bin/sh` | JDK defaults to vfork, which breaks under Rosetta → `JAVA_TOOL_OPTIONS=-Djdk.lang.Process.launchMechanism=FORK` |
| Downloads die with `NoRouteToHostException` | AMD's Akamai CDN returns AAAA records; the VZ NAT is IPv4-only → `-Djava.net.preferIPv4Stack=true` + independent guest DNS |
| `synth_design failed` with bare error `stoi` **(new in 2026.1)** | The new FeatureStore execs `/usr/bin/lscpu` by absolute path and `std::stoi`'s the values; ARM lscpu prints `Socket(s): -` → divert lscpu, emit an x86-style view (found via an `__cxa_throw` backtrace hook) |
| `libpixman-1.so.0` / `libncurses.so.5` missing | amd64 multiarch package set + symlinks to AMD's own bundled Ubuntu/24 compat libs |
| `realloc(): invalid pointer` in license manager | libudev under Rosetta (not reproduced on 2026.1; stub kept as opt-in: `LD_PRELOAD=/opt/Xilinx/udev_stub_x86_64.so`) |
| x86-64 binaries: `failed to open elf /lib64/ld-linux-x86-64.so.2` | An arm64 userland has no x86-64 loader — Debian-style amd64 **multiarch** provides the x86-64 glibc/X stack (this is what Docker images get for free by being amd64 userlands) |

## Limitations

- Headless only — no GUI (that's the point; see [ichi4096/vivado-on-silicon-mac](https://github.com/ichi4096/vivado-on-silicon-mac) for a Docker+VNC approach)
- No USB JTAG passthrough. Bitstreams land in `~/vivado-work`; flash with [openFPGALoader](https://github.com/trabucayre/openFPGALoader) (native on macOS) or XVC
- Rosetta speed is roughly 70–80 % of native x86; big UltraScale+ builds belong on a real x86 box
- Apple guarantees Rosetta 2 through macOS 27 (WWDC 2025); macOS 28 is a question mark

## Credits

- [ichi4096/vivado-on-silicon-mac](https://github.com/ichi4096/vivado-on-silicon-mac) and the [minorin22 fork](https://github.com/minorin22/vivado-on-silicon-mac) — the Docker + VNC pioneers
- [filmil/vivado-docker](https://github.com/filmil/vivado-docker) — the udev-stub and in-process-Tcl workarounds for 2025.x
