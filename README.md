# vivado-mac-cli

Run AMD **Vivado 2026.1 natively-ish on Apple Silicon Macs** — headless (CLI) by default, with an optional native-window GUI through XQuartz. No Docker, no Lima. [日本語 README](README.ja.md)

A zero-dependency Swift CLI (`vivado-mac`) drives Apple's **Virtualization.framework** directly: it boots an Ubuntu 24.04 ARM64 VM, injects **Rosetta 2** into it, and runs the x86-64 Linux Vivado at near-native speed over SSH.

**Verified end-to-end** (M4 Mac, macOS 26.5, 2026-08): full `synth_design → opt_design → place_design → route_design → write_bitstream` flow producing a working bitstream for an Artix-7 (xc7a35t), using the free BASIC-tier license. **Second verification** (M1 Pro, macOS 27.0.1, 2026-10): same flow for a **Zynq UltraScale+ ZU2EG** (`xczu2eg-sbva484-1-e`), 2 min 23 s wall time for a small design, BASIC license; Vivado installed through AMD's GUI installer over XQuartz (`install --gui`), and a guest `fstrim` returned 112 GiB of freed blocks to the Mac — so the sparse disk really does shrink.

```
Mac (Apple Silicon)
├─ XQuartz (optional, via Homebrew) ⇐ ssh -Y: Vivado's GUI windows land on the Mac desktop
├─ usbipd-mac (optional, built by `jtag setup`) ⇒ USB/IP: the JTAG cable appears inside the VM
└─ vivado-mac (Swift CLI, zero deps, ad-hoc signed)
   └─ Virtualization.framework VM: Ubuntu 24.04 ARM64
      ├─ Rosetta 2 (VZLinuxRosettaDirectoryShare + binfmt_misc) ← x86-64 AOT translation
      ├─ Vivado 2026.1 (x86-64) at /opt/Xilinx (on the VM disk)
      └─ /work ⇄ ~/vivado-work on the Mac (virtiofs)
```

The VM is **not resident**: it auto-boots when you run a command (~30 s) and powers itself off after 15 idle minutes (configurable, `--idle 0` = stay up). A running command always keeps it alive.

## What's new here

Excellent prior art exists for Vivado on Apple Silicon — [ichi4096/vivado-on-silicon-mac](https://github.com/ichi4096/vivado-on-silicon-mac) (Docker + VNC GUI) and [filmil/vivado-docker](https://github.com/filmil/vivado-docker) (Docker headless) — but both target Vivado ≤ 2025.x. As far as we can tell, this project is first on four fronts:

1. **Vivado 2026.1 actually working on Apple Silicon.** 2026.1's new FeatureStore execs `/usr/bin/lscpu` and `std::stoi`'s the values, so on any ARM-flavored environment `synth_design` dies with the bare error `stoi` *after synthesis completes*. We root-caused this with an `__cxa_throw` backtrace hook and fixed it with an lscpu shim — documented nowhere else. If you landed here by googling `vivado synth_design failed stoi`: see the [workaround catalog](#the-rosetta-workaround-catalog).
2. **No container runtime at all.** Instead of an amd64 userland in Docker, this uses an ARM-native Ubuntu with Debian **multiarch** x86-64 libraries — everything except Vivado itself runs natively. No Docker Desktop (and no Docker Desktop corporate licensing), no image management; the only dependency is the Xcode Command Line Tools.
3. **A workaround set specific to this hybrid** that container users never see (and therefore never documented): the `uname` shim for installer scripts running under ARM bash, the JDK vfork→FORK fix for Rosetta, IPv4-forcing for AMD's AAAA-resolving CDN inside an IPv4-only NAT.
4. **Designed for 2026.1's mandatory licensing**: the VM's MAC address is pinned and persisted so the free BASIC-tier node-locked license survives VM rebuilds — prior projects predate license enforcement.

Honest caveats: Rosetta 2 is guaranteed only through macOS 27 (per WWDC 2025), translation costs ~20–30 % versus native x86, and the free tier covers 7-series devices — big UltraScale+ jobs still belong on a real x86 machine.

## Requirements

- Apple Silicon Mac, macOS 13+ (macOS 15+ recommended — Rosetta 2 gained AVX2 there)
- Xcode Command Line Tools (`swift`). No Docker. Homebrew only if you want the GUI (it installs XQuartz)
- ~120 GB free disk for the 7-series device set; each extra family (e.g. Zynq UltraScale+ MPSoC) adds ~10–20 GB. The VM disk is a **sparse** file: the Mac only pays for blocks the guest has actually written, never for the free space inside the VM (`vivado-mac status` shows real usage next to the ceiling). 16 GB+ RAM recommended
- An AMD account (for the installer download and the free license)

## Install

```bash
make build
sudo make install     # /usr/local/bin/vivado-mac (build first; install does not rebuild)
vivado-mac setup      # create + provision the VM (one-time, a few minutes)
```

`setup` downloads the Ubuntu cloud image (SHA256-verified), converts qcow2→raw with a built-in stdlib-only converter, provisions via cloud-init (amd64 multiarch, Rosetta binfmt, all workarounds below), and smoke-tests that x86-64 dynamically linked binaries actually execute.

Then download the Vivado web installer (`FPGAs_AdaptiveSoCs_Unified_SDI_*_Lin64.bin`, AMD login required) from [AMD's download page](https://www.amd.com/en/support/downloads/adaptive-socs-and-fpgas/development-tools.html) and:

```bash
vivado-mac install    # finds the installer in ~/Downloads automatically
```

Interactive AMD token auth → edition pick (choose Vivado) → EULA confirm → ~22 GB download + install.

If the token step answers `Invalid E-mail Address or Password` for a login that works on amd.com, that is AMD's batch installer, not the terminal: its legacy `xilinx.com/.../oauth/login` endpoint returns 401 for some accounts while the graphical installer accepts the same credentials (seen 2026-10 with a fresh AMD account; the ssh/pty path was verified to deliver the password byte-for-byte). Use the GUI instead — it needs the [XQuartz setup](#gui-optional-through-xquartz):

```bash
vivado-mac install --gui      # AMD's installer window on the Mac desktop, then the same post-install fixes
```

## Licensing (changed in 2026.1)

Vivado 2026.1 requires a license even for basic use. The free **BASIC tier** is node-locked to a MAC address — and `vivado-mac` pins the VM's MAC permanently, so:

1. `vivado-mac status` → note the VM MAC
2. Generate a free BASIC license at https://www.xilinx.com/getlicense for that MAC
3. Save it as `~/vivado-work/Xilinx.lic` — done (`XILINXD_LICENSE_FILE` is pre-wired)

`vivado-mac destroy` regenerates the MAC → you'd need to re-host the license (AMD allows once a year). Don't destroy casually.

BASIC covers, per [AMD's tier table](https://www.amd.com/en/products/software/adaptive-socs-and-fpgas/vivado/vivado-licensing-options.html): all 7-series, Spartan/Artix UltraScale+, Kintex UltraScale+ KU3P/KU5P, and **Zynq UltraScale+ MPSoC ZU1–ZU7** (CG/EG) — so a ZU2EG board is in. Tick the matching device families during `vivado-mac install` (ConfigGen); families can't be removed afterwards. BASIC excludes ILA/debug cores and IBERT, and the license must be renewed (free) every 12 months. If your `.lic` mixes tiers (e.g. BASIC + an Alveo entitlement), Vivado takes the first tier it finds — keep only the BASIC lines in `Xilinx.lic`.

## Usage

```bash
vivado-mac vivado -mode batch -source build.tcl   # cwd is /work (= ~/vivado-work)
vivado-mac vivado -mode tcl                       # interactive Tcl
vivado-mac run make -j8                           # any guest command (argv form)
vivado-mac run 'ls *.bit && df -h /'              # single arg = shell string
vivado-mac shell                                  # SSH into the guest
vivado-mac start / stop / status / doctor / version
```

### GUI (optional, through XQuartz)

```bash
vivado-mac gui-setup          # once: XQuartz via Homebrew, guest xauth/fonts, display test
vivado-mac gui                # Vivado GUI — every window is a native XQuartz window on the Mac
vivado-mac gui proj/top.xpr   # open a project (paths relative to ~/vivado-work)
vivado-mac run --x11 CMD      # any other X11 program in the guest
vivado-mac shell --x11        # shell with the display forwarded
vivado-mac tcl 'CMD'          # send Tcl into the running GUI session; no CMD = a vivado% prompt
```

**Tcl from the Mac terminal while the GUI is open.** Vivado has no remote Tcl, and after `start_gui` its console lives in the GUI only. `vivado-mac gui` therefore sources a small bridge (`/work/.vivado-mac/tclserver.tcl`, a `socket -server` on 127.0.0.1 inside the VM, reachable only over vivado-mac's ssh) and `vivado-mac tcl` talks to it: `vivado-mac tcl 'open_project /work/p/p.xpr'`, `vivado-mac tcl 'launch_runs synth_1'`, or plain `vivado-mac tcl` for a prompt with history. Commands run in the GUI's interpreter, so the IDE updates live. What a command *prints* (`puts`, `report_*` without `-return_string`) still lands in the GUI's Tcl Console; the command's return value is what comes back. For a GUI started some other way, run `source /work/.vivado-mac/tclserver.tcl` in its Tcl Console once.

This is plain **`ssh -Y` X11 forwarding** into the same headless VM — Vivado's Java/Swing GUI speaks X11, XQuartz is the X server. No VNC, no desktop environment, no virtual graphics device; the VM is byte-identical to the headless one apart from four small arm64 packages (`xauth`, fonts, `xdpyinfo`). A GUI session holds the activity lock, so idle auto-shutdown never fires while Vivado is open.

- **XQuartz ≥ 2.8.6 is required.** Older builds crash `xauth` on macOS 27 ([XQuartz#520](https://github.com/XQuartz/XQuartz/issues/520)) — exactly the step ssh runs for forwarding — and the 2.8.7 betas crash on 27.0.1 ([#524](https://github.com/XQuartz/XQuartz/issues/524)). `gui-setup` installs through `brew install --cask xquartz` (currently exactly 2.8.6); if a manually installed XQuartz is in the way it prints the [official uninstall steps](https://www.xquartz.org/FAQs.html). Without Homebrew it downloads the signed pkg and verifies its SHA-256.
- After a first-time XQuartz install, log out and back in once (launchd sets `DISPLAY` at login). `vivado-mac` finds the display socket without it, other X11 tools won't.
- **Run Synthesis / Implementation from the GUI uses `launch_runs`** (see below) — the one path known to be flaky under Rosetta. If a run dies, drive the build from in-process Tcl and use the GUI for everything else (project setup, IP integrator, schematic/device views, hardware manager, reports).
- Known quirks: a window that stays black → resize it once (XQuartz redraw); macOS 27 Mission Control can't minimize X11 windows ([#519](https://github.com/XQuartz/XQuartz/issues/519), Apple bug); Java2D over a forwarded display is slower than native — the wrapper already sets `-Dsun.java2d.pmoffscreen=false`, and `J2D_USE_MITSHM=false` / `_JAVA_AWT_WM_NONREPARENTING=1` are documented opt-ins in `/usr/local/bin/vivado`.
- **Status (2026-10): verified.** `vivado-mac gui` opens the Vivado 2026.1 IDE (main window + welcome dialog) as native XQuartz 2.8.6 windows under Rosetta on macOS 27; AMD's Java installer GUI works the same way. Not yet exercised from the GUI: *Run Synthesis* (the `launch_runs` child-process path) — build from in-process Tcl if it misbehaves. Found and fixed on the way: an `~/.ssh/config` with `ControlMaster auto` made forwarded sessions get no `DISPLAY`; vivado-mac now disables connection sharing for its own ssh calls.

### USB JTAG cable (optional, over USB/IP)

```bash
vivado-mac jtag attach        # plug the cable/board in first; builds usbipd-mac on first use (~3 min)
vivado-mac jtag status        # what the Mac sees, what the guest has attached, hw_server state
vivado-mac jtag detach        # give the cable back to macOS (--stop also stops the daemon)
```

Virtualization.framework has no USB passthrough, so the cable is shared from the Mac over **USB/IP**: [usbipd-mac](https://github.com/beriberikix/usbipd-mac) (pure Swift, MIT; drives the device from userspace through IOKit — no root, no kernel/system extension) serves it on port 3240, and the guest kernel's `vhci-hcd` imports it with the standard `usbip` client, so Vivado's `hw_server` (x86-64, under Rosetta) sees an ordinary USB device. `jtag setup` clones usbipd-mac at a pinned commit, applies the two fixes from [tae2yi/vivado-on-mac](https://github.com/tae2yi/vivado-on-mac) (TCP stream framing of the import request, serial per-endpoint URB queues — without them the cable attaches but programming stalls) and builds it into `~/.vivado-mac`. The guest side (`linux-tools-virtual`, `linux-modules-extra-<kernel>`, Vivado's `52-xilinx-*.rules` via `install_drivers`) installs itself on the first attach; because this VM runs a real udev, Vivado's cable rules handle permissions and the `ftdi_sio` unbind like on any Linux box.

- Cables are found by the vendor IDs Vivado's rules cover: `03fd` Platform Cable USB/USB II, `0403` FTDI-based (Xilinx and Digilent on-board JTAG), `1443` Digilent. `--busid` picks a specific device.
- A **Platform Cable USB II** enumerates as `03fd:0013` until hw_server loads its firmware, then re-enumerates as `03fd:0008`; `jtag attach` selects its USB configuration (macOS leaves it unconfigured), starts hw_server, waits for the `0008` identity and re-shares it. First connect ≈ 40 s. Don't press Auto Connect before `jtag attach` prints ✅ — Vivado otherwise reports `[Xicom 50-198] Cannot support out-of-date hw_server` and hangs for half a minute.
- macOS may ask once whether `usbipd` may accept incoming connections: allow it (the only client is the VM, on the NAT bridge).
- Devices macOS has bound a kernel driver to (HID, storage, audio, cameras) can't be shared — Apple declined usbipd-mac the DriverKit entitlement. JTAG cables are vendor-specific and unaffected.
- Don't unplug the cable or restart usbipd mid-programming: a Platform Cable left mid-transaction stops answering until it is physically re-plugged.
- **Status: implemented, not yet verified on hardware here** (2026-10). tae2yi verified the same chain (usbipd-mac + patch → vhci-hcd → hw_server under Rosetta) with a Platform Cable USB II on Vivado 2026.1; FTDI/Digilent cables are handled by vendor ID but nobody has run them through it yet. `vivado-mac destroy` removes the usbipd-mac build along with the VM (it rebuilds on the next `jtag attach`).

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

- The GUI is X11-forwarded Java Swing, not a local desktop: slower than native, Mission Control quirks on macOS 27, and unverified on 2026.1 so far (see [GUI](#gui-optional-through-xquartz)). For a full Linux desktop over VNC see [ichi4096/vivado-on-silicon-mac](https://github.com/ichi4096/vivado-on-silicon-mac)
- USB JTAG goes through USB/IP (see [above](#usb-jtag-cable-optional-over-usbip)), not native passthrough; unverified here so far. Without a cable, bitstreams land in `~/vivado-work` and [openFPGALoader](https://github.com/trabucayre/openFPGALoader) (native on macOS) flashes them
- Rosetta speed is roughly 70–80 % of native x86; big UltraScale+ builds belong on a real x86 box
- Apple guarantees Rosetta 2 through macOS 27 (WWDC 2025); macOS 28 is a question mark

## Credits

- [ichi4096/vivado-on-silicon-mac](https://github.com/ichi4096/vivado-on-silicon-mac) and the [minorin22 fork](https://github.com/minorin22/vivado-on-silicon-mac) — the Docker + VNC pioneers
- [filmil/vivado-docker](https://github.com/filmil/vivado-docker) — the udev-stub and in-process-Tcl workarounds for 2025.x
- [andrivet/vivado-on-silicon-mac-x11](https://github.com/andrivet/vivado-on-silicon-mac-x11) — first to put Vivado's GUI on the Mac desktop through XQuartz (Docker + direct TCP; we use ssh -Y instead)
- [tae2yi/vivado-on-mac](https://github.com/tae2yi/vivado-on-mac) — JTAG over USB/IP with usbipd-mac, including the two usbipd-mac fixes this tool embeds (CC0); [beriberikix/usbipd-mac](https://github.com/beriberikix/usbipd-mac) — the USB/IP server itself (MIT)
