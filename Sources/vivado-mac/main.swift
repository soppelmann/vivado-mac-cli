import Foundation

let usage = """
vivado-mac — AMD Vivado on Apple Silicon, headless (Virtualization.framework + Rosetta 2)

USAGE:
  vivado-mac setup [--cpus N] [--memory GiB] [--disk GiB] [--work PATH]
                          create + provision the Ubuntu 24.04 VM (one-time)
  vivado-mac install PATH/TO/FPGAs_..._Lin64.bin [--config FILE] [--accept-eulas]
                          install Vivado into the VM (batch mode)
  vivado-mac vivado [ARGS...]   run vivado in the guest (e.g. -mode batch -source x.tcl)
  vivado-mac run CMD [ARGS...]  run any command in the guest work dir
  vivado-mac shell              interactive shell in the guest
  vivado-mac start | stop | status | doctor
  vivado-mac destroy            delete the VM and all state (work dir is kept)

Vivado projects live in the shared work dir (default ~/vivado-work), which is
/work inside the guest. Put your license file there as Xilinx.lic.
"""

let imageURL = "https://cloud-images.ubuntu.com/releases/noble/release/ubuntu-24.04-server-cloudimg-arm64.img"
let imageSHAURL = "https://cloud-images.ubuntu.com/releases/noble/release/SHA256SUMS"
let imageName = "ubuntu-24.04-server-cloudimg-arm64.img"

// MARK: - small helpers

func parseFlags(_ args: [String], valueFlags: Set<String>) -> (flags: [String: String], positional: [String]) {
    var flags: [String: String] = [:]
    var positional: [String] = []
    var i = 0
    while i < args.count {
        let a = args[i]
        if valueFlags.contains(a), i + 1 < args.count {
            flags[a] = args[i + 1]
            i += 2
        } else if a.hasPrefix("--") {
            flags[a] = ""
            i += 1
        } else {
            positional.append(a)
            i += 1
        }
    }
    return (flags, positional)
}

/// Two-stage x86-64 check: run the amd64 dynamic linker directly (pure
/// Rosetta + multiarch glibc), then compile & run a dynamically linked binary.
let rosettaSmokeTest =
    "if ! /lib64/ld-linux-x86-64.so.2 --version >/dev/null 2>&1; then echo LDSO_FAIL; " +
    "elif printf 'int main(){return 42;}' > /tmp/t.c && x86_64-linux-gnu-gcc /tmp/t.c -o /tmp/t42 && /tmp/t42; " +
    "[ $? -eq 42 ]; then echo ROSETTA_OK; else echo COMPILE_FAIL; fi"

func loadConfigOrDie() -> Config {
    guard let cfg = Config.load() else {
        die("not set up yet — run `vivado-mac setup` first")
    }
    return cfg
}

func spawnVMHost() {
    FileManager.default.createFile(atPath: Paths.vmhostLog.path, contents: nil)
    let logFH = FileHandle(forWritingAtPath: Paths.vmhostLog.path)
    logFH?.seekToEndOfFile()
    let p = Process()
    p.executableURL = URL(fileURLWithPath: Bundle.main.executablePath!)
    p.arguments = ["__vmhost"]
    p.standardInput = FileHandle.nullDevice
    p.standardOutput = logFH ?? FileHandle.nullDevice
    p.standardError = logFH ?? FileHandle.nullDevice
    do { try p.run() } catch { die("failed to spawn VM host: \(error)") }
}

/// Start the VM if needed and return a reachable guest IP.
func ensureRunning(_ cfg: Config) -> String {
    if vmPID() != nil {
        if let ip = waitForSSH(mac: cfg.macAddress, timeoutSeconds: 15) { return ip }
        die("VM process is running but SSH is unreachable — check \(Paths.vmhostLog.path)")
    }
    note("starting VM …")
    spawnVMHost()
    guard let ip = waitForSSH(mac: cfg.macAddress, timeoutSeconds: 180) else {
        die("VM did not become reachable — check \(Paths.vmhostLog.path) and \(Paths.consoleLog.path)")
    }
    return ip
}

func b64(_ s: String) -> String { Data(s.utf8).base64EncodedString() }

// MARK: - setup

func cmdSetup(_ args: [String]) throws {
    let (flags, _) = parseFlags(args, valueFlags: ["--cpus", "--memory", "--disk", "--work"])
    let fm = FileManager.default

    switch RosettaState.current() {
    case .notSupported:
        die("Rosetta 2 for Linux VMs is not supported on this machine (Apple Silicon required)")
    case .notInstalled:
        note("Rosetta 2 is not installed — installing (softwareupdate) …")
        if run("/usr/sbin/softwareupdate", ["--install-rosetta", "--agree-to-license"]) != 0 {
            die("Rosetta 2 install failed — run `softwareupdate --install-rosetta` manually")
        }
        guard RosettaState.current() == .installed else { die("Rosetta 2 still unavailable") }
    case .installed:
        break
    }
    note("Rosetta 2: installed")

    let defaultMemory = max(8, min(32, Int(ProcessInfo.processInfo.physicalMemory >> 30) / 2))
    var cfg = Config.load() ?? Config(
        cpus: ProcessInfo.processInfo.activeProcessorCount,
        memoryGiB: defaultMemory,
        diskGiB: 200,
        workDir: fm.homeDirectoryForCurrentUser.appendingPathComponent("vivado-work").path,
        macAddress: "",
        machineID: "")
    for (flag, path) in [("--cpus", \Config.cpus), ("--memory", \Config.memoryGiB), ("--disk", \Config.diskGiB)] {
        if let raw = flags[flag] {
            guard let v = Int(raw), v > 0 else { die("\(flag) must be a positive integer (got '\(raw)')") }
            cfg[keyPath: path] = v
        }
    }
    if let v = flags["--work"] { cfg.workDir = (v as NSString).expandingTildeInPath }

    try fm.createDirectory(at: Paths.stateDir, withIntermediateDirectories: true)
    try fm.createDirectory(atPath: cfg.workDir, withIntermediateDirectories: true)

    if !fm.fileExists(atPath: Paths.sshKey.path) {
        note("generating SSH key …")
        guard run("/usr/bin/ssh-keygen",
                  ["-t", "ed25519", "-N", "", "-C", "vivado-mac", "-f", Paths.sshKey.path],
                  quiet: true) == 0 else { die("ssh-keygen failed") }
    }

    if !fm.fileExists(atPath: Paths.baseImage.path) {
        note("downloading Ubuntu 24.04 arm64 cloud image (~600 MB) …")
        let tmp = Paths.baseImage.path + ".part"
        guard run("/usr/bin/curl", ["-fL", "--progress-bar", "-o", tmp, imageURL]) == 0 else {
            die("download failed")
        }
        note("verifying SHA256 …")
        let (s1, sums) = capture("/usr/bin/curl", ["-fsSL", imageSHAURL])
        guard s1 == 0,
              let line = sums.split(separator: "\n").first(where: { $0.contains(imageName) }),
              let expected = line.split(separator: " ").first else {
            die("could not fetch/parse SHA256SUMS")
        }
        let (s2, out) = capture("/usr/bin/shasum", ["-a", "256", tmp])
        guard s2 == 0, out.hasPrefix(String(expected)) else {
            die("SHA256 mismatch for downloaded image")
        }
        try? fm.removeItem(at: Paths.baseImage)
        try fm.moveItem(atPath: tmp, toPath: Paths.baseImage.path)
    }

    if !fm.fileExists(atPath: Paths.diskImage.path) {
        note("converting qcow2 → raw (sparse) …")
        let conv = Paths.stateDir.appendingPathComponent("qcow2_to_raw.py")
        try Assets.qcow2Converter.write(to: conv, atomically: true, encoding: .utf8)
        guard run("/usr/bin/python3",
                  [conv.path, Paths.baseImage.path, Paths.diskImage.path, "--expect-gpt"]) == 0 else {
            try? fm.removeItem(at: Paths.diskImage)
            die("qcow2 conversion failed")
        }
        let baseSize = fileSize(Paths.diskImage)
        let minGiB = Int((baseSize + (1 << 30) - 1) >> 30)
        guard UInt64(cfg.diskGiB) << 30 >= baseSize else {
            try? fm.removeItem(at: Paths.diskImage)
            die("--disk must be at least \(minGiB) GiB (base image size)")
        }
        let fh = try FileHandle(forWritingTo: Paths.diskImage)
        try fh.truncate(atOffset: UInt64(cfg.diskGiB) << 30)
        try fh.close()
        note("disk resized to \(cfg.diskGiB) GiB (sparse; cloud-init grows the filesystem)")
    } else {
        // the filesystem was grown on first boot; the size is fixed after creation
        let actualGiB = Int(fileSize(Paths.diskImage) >> 30)
        if let want = flags["--disk"].flatMap(Int.init), want != actualGiB {
            note("disk size is fixed at creation (\(actualGiB) GiB) — `vivado-mac destroy` and re-setup to change it")
        }
        cfg.diskGiB = actualGiB
        note("disk.img already exists — keeping it (use `vivado-mac destroy` to reset)")
    }

    if cfg.macAddress.isEmpty {
        cfg.macAddress = randomMACAddress()
        note("VM MAC address: \(cfg.macAddress)  (Vivado licenses are node-locked to this)")
    }
    if cfg.machineID.isEmpty { cfg.machineID = newMachineIdentifierB64() }
    try cfg.save()

    if !fm.fileExists(atPath: Paths.seedISO.path) {
        note("building cloud-init seed ISO …")
        let pubkey = (try String(contentsOf: Paths.sshPubKey, encoding: .utf8))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let seedDir = Paths.stateDir.appendingPathComponent("seed")
        try? fm.removeItem(at: seedDir)
        try fm.createDirectory(at: seedDir, withIntermediateDirectories: true)
        try Assets.userDataTemplate
            .replacingOccurrences(of: "@@PUBKEY@@", with: pubkey)
            .write(to: seedDir.appendingPathComponent("user-data"), atomically: true, encoding: .utf8)
        try Assets.metaData
            .write(to: seedDir.appendingPathComponent("meta-data"), atomically: true, encoding: .utf8)
        try Assets.networkConfig
            .write(to: seedDir.appendingPathComponent("network-config"), atomically: true, encoding: .utf8)
        guard run("/usr/bin/hdiutil",
                  ["makehybrid", "-iso", "-joliet", "-ov", "-default-volume-name", "cidata",
                   "-o", Paths.seedISO.path, seedDir.path], quiet: true) == 0 else {
            die("hdiutil failed to build seed ISO")
        }
    }

    let ip = ensureRunning(cfg)
    note("VM is up at \(ip) — waiting for cloud-init provisioning (installs packages; a few minutes) …")
    _ = sshExec(ip, "sudo cloud-init status --wait")

    note("verifying Rosetta x86-64 execution …")
    let (_, out) = sshCapture(ip, rosettaSmokeTest)
    guard out.contains("ROSETTA_OK") else {
        die("""
        Rosetta smoke test failed (\(out.trimmingCharacters(in: .whitespacesAndNewlines))).
        Inspect with:  vivado-mac run 'sudo cloud-init status --long'
                       vivado-mac run 'sudo tail -50 /var/log/cloud-init-output.log'
        Then retry provisioning with:  vivado-mac run 'sudo /usr/local/sbin/vivado-provision.sh'
        """)
    }
    note("Rosetta x86-64 execution: OK (dynamic linking verified)")

    print("""

    ✅ setup complete
       guest IP:   \(ip)
       work dir:   \(cfg.workDir)  (= /work in the guest)
       VM MAC:     \(cfg.macAddress)

    Next:
      1. Download the Vivado 2026.1 Linux web installer (login required):
         https://www.amd.com/en/support/downloads/adaptive-socs-and-fpgas/development-tools/2026-1.html
         → FPGAs_AdaptiveSoCs_Unified_SDI_2026.1_*_Lin64.bin
      2. vivado-mac install ~/Downloads/FPGAs_AdaptiveSoCs_Unified_SDI_2026.1_*_Lin64.bin
    """)
}

// MARK: - install

func cmdInstall(_ args: [String]) throws {
    let (flags, positional) = parseFlags(args, valueFlags: ["--config"])
    guard let installerArg = positional.first else {
        die("usage: vivado-mac install PATH/TO/FPGAs_..._Lin64.bin [--config FILE] [--accept-eulas]")
    }
    let cfg = loadConfigOrDie()
    let fm = FileManager.default
    let installerSrc = URL(fileURLWithPath: (installerArg as NSString).expandingTildeInPath)
    guard fm.fileExists(atPath: installerSrc.path) else { die("installer not found: \(installerSrc.path)") }
    let binName = installerSrc.lastPathComponent

    let workInstaller = URL(fileURLWithPath: cfg.workDir).appendingPathComponent(binName)
    if !fm.fileExists(atPath: workInstaller.path) {
        note("copying installer into work dir …")
        try fm.copyItem(at: installerSrc, to: workInstaller)
    }

    let ip = ensureRunning(cfg)

    note("extracting installer …")
    let qBin = shellQuote(binName)
    guard sshExec(ip, "cd /work && chmod +x \(qBin) && rm -rf /work/.installer && " +
        "./\(qBin) --noexec --nox11 --target /work/.installer") == 0 else {
        die("installer extraction failed")
    }

    let (_, tokenCheck) = sshCapture(ip, "test -f ~/.Xilinx/wi_authentication_key && echo yes")
    if !tokenCheck.contains("yes") {
        note("AMD account login (AuthTokenGen) — enter your AMD/Xilinx credentials:")
        guard sshExec(ip, "PATH=/opt/vivado-shim:$PATH /work/.installer/xsetup -b AuthTokenGen", tty: true) == 0 else {
            die("AuthTokenGen failed — rerun `vivado-mac install` to retry")
        }
    }

    let guestConfig = "/work/install_config.txt"
    if let local = flags["--config"] {
        let src = URL(fileURLWithPath: (local as NSString).expandingTildeInPath).resolvingSymlinksInPath()
        let dst = URL(fileURLWithPath: cfg.workDir).appendingPathComponent("install_config.txt")
        guard fm.fileExists(atPath: src.path) else { die("config not found: \(src.path)") }
        if src.path != dst.resolvingSymlinksInPath().path {
            try? fm.removeItem(at: dst)
            try fm.copyItem(at: src, to: dst)
        }
        _ = sshExec(ip, "sed -i 's|^Destination=.*|Destination=/opt/Xilinx|' \(guestConfig)")
        note("Destination forced to /opt/Xilinx (the wrapper and PATH setup expect it)")
    }
    let (_, cfgCheck) = sshCapture(ip, "test -f \(guestConfig) && echo yes")
    if !cfgCheck.contains("yes") {
        note("generating install config (choose edition/devices; ConfigGen is interactive) …")
        guard sshExec(ip, "PATH=/opt/vivado-shim:$PATH /work/.installer/xsetup -b ConfigGen", tty: true) == 0 else {
            die("ConfigGen failed")
        }
        _ = sshExec(ip, "cp ~/.Xilinx/install_config.txt \(guestConfig) && " +
            "sed -i 's|^Destination=.*|Destination=/opt/Xilinx|' \(guestConfig)")
        note("install config written to \(cfg.workDir)/install_config.txt (Destination → /opt/Xilinx)")
    }
    let (_, cfgText) = sshCapture(ip, "cat \(guestConfig)")
    print("---- install_config.txt ----\n\(cfgText)----------------------------")

    if flags["--accept-eulas"] == nil {
        print("Continue installing with the above config? This accepts the AMD XilinxEULA and 3rdPartyEULA. [y/N] ", terminator: "")
        guard let a = readLine(), a.lowercased().hasPrefix("y") else { die("aborted") }
    }

    note("installing Vivado (downloads tens of GB; can take 1–3 h) …")
    _ = sshExec(ip, "sudo mkdir -p /opt/Xilinx && sudo chown vivado:vivado /opt/Xilinx")
    guard sshExec(ip, "PATH=/opt/vivado-shim:$PATH /work/.installer/xsetup --agree XilinxEULA,3rdPartyEULA --batch Install " +
        "--config \(guestConfig)", tty: true) == 0 else {
        die("xsetup Install failed — rerun `vivado-mac install` to resume/retry")
    }

    note("post-install: OS libraries (installLibs.sh, CRLF fix) …")
    _ = sshExec(ip, "f=$(find /work/.installer /opt/Xilinx -name installLibs.sh 2>/dev/null | head -1); " +
        "if [ -n \"$f\" ]; then sudo sed -i 's/\\r$//' \"$f\"; sudo bash \"$f\" || true; fi")

    note("post-install: Rosetta udev workaround + wrappers …")
    _ = sshExec(ip, "echo \(b64(Assets.udevStubC)) | base64 -d > /tmp/udev_stub.c && " +
        "x86_64-linux-gnu-gcc -shared -fPIC -O2 /tmp/udev_stub.c -o /opt/Xilinx/udev_stub.so")
    _ = sshExec(ip, "echo \(b64(Assets.vivadoWrapper)) | base64 -d | sudo tee /usr/local/bin/vivado >/dev/null && " +
        "sudo chmod +x /usr/local/bin/vivado")
    _ = sshExec(ip, "echo \(b64(Assets.profileScript)) | base64 -d | sudo tee /etc/profile.d/vivado.sh >/dev/null")

    print("""

    ✅ Vivado installed.

    License (required since 2026.1 — free BASIC tier works):
      1. Generate a free BASIC license at https://www.xilinx.com/getlicense
         using this MAC address: \(cfg.macAddress)
      2. Save it as \(cfg.workDir)/Xilinx.lic

    Try:  vivado-mac vivado -version
          vivado-mac vivado -mode batch -source build.tcl
    Note: under Rosetta, prefer in-process Tcl (synth_design, place_design, …)
          over launch_runs — child-process spawning is the known crash path.
    """)
}

// MARK: - passthrough commands

func cmdVivado(_ args: [String]) {
    let cfg = loadConfigOrDie()
    let ip = ensureRunning(cfg)
    let quoted = args.map(shellQuote).joined(separator: " ")
    exit(sshExec(ip, "cd /work && vivado \(quoted)", tty: stdinIsTTY))
}

func cmdRun(_ args: [String]) {
    guard !args.isEmpty else { die("usage: vivado-mac run CMD [ARGS...]") }
    let cfg = loadConfigOrDie()
    let ip = ensureRunning(cfg)
    // single arg = shell string (`run 'a && b'`), multiple = quoted argv (`run make -j8`)
    let cmd = args.count == 1 ? args[0] : args.map(shellQuote).joined(separator: " ")
    exit(sshExec(ip, "cd /work && \(cmd)", tty: stdinIsTTY))
}

func cmdShell() {
    let cfg = loadConfigOrDie()
    let ip = ensureRunning(cfg)
    exit(sshInteractive(ip))
}

// MARK: - lifecycle

func cmdStart() {
    let cfg = loadConfigOrDie()
    if vmPID() != nil, let ip = waitForSSH(mac: cfg.macAddress, timeoutSeconds: 10) {
        note("already running at \(ip)")
        return
    }
    let ip = ensureRunning(cfg)
    note("running at \(ip)")
}

func cmdStop() {
    guard let pid = vmPID() else {
        note("not running")
        return
    }
    let cfg = loadConfigOrDie()
    if let ip = discoverIP(mac: cfg.macAddress) {
        note("shutting down guest …")
        _ = sshExec(ip, "sudo shutdown -h now")
    }
    for _ in 0..<60 where kill(pid, 0) == 0 { Thread.sleep(forTimeInterval: 1) }
    if kill(pid, 0) == 0 {
        note("guest did not power off — terminating VM host")
        kill(pid, SIGTERM)
        for _ in 0..<40 where kill(pid, 0) == 0 { Thread.sleep(forTimeInterval: 1) }
        if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
    }
    try? FileManager.default.removeItem(at: Paths.pidFile)
    note("stopped")
}

func cmdStatus() {
    guard let cfg = Config.load() else {
        print("not set up (run `vivado-mac setup`)")
        return
    }
    print("config:   \(cfg.cpus) CPUs, \(cfg.memoryGiB) GiB RAM, \(cfg.diskGiB) GiB disk")
    print("work dir: \(cfg.workDir)")
    print("VM MAC:   \(cfg.macAddress)")
    guard let pid = vmPID() else {
        print("VM:       stopped")
        return
    }
    print("VM:       running (pid \(pid))")
    guard let ip = discoverIP(mac: cfg.macAddress) else {
        print("SSH:      unreachable")
        return
    }
    print("SSH:      ok (\(ip))")
    let (_, rosetta) = sshCapture(ip, "test -e /proc/sys/fs/binfmt_misc/rosetta && echo registered")
    print("Rosetta:  \(rosetta.contains("registered") ? "binfmt registered" : "NOT registered")")
    let (_, viv) = sshCapture(ip, "ls -d /opt/Xilinx/*/Vivado /opt/Xilinx/Vivado/* 2>/dev/null | head -1")
    let vivDir = viv.trimmingCharacters(in: .whitespacesAndNewlines)
    print("Vivado:   \(vivDir.isEmpty ? "not installed" : vivDir)")
    let (_, lic) = sshCapture(ip, "test -f /work/Xilinx.lic && echo yes")
    print("License:  \(lic.contains("yes") ? "/work/Xilinx.lic present" : "no /work/Xilinx.lic (needed since 2026.1)")")
}

func cmdDoctor() {
    print("host:")
    print("  macOS:    \(ProcessInfo.processInfo.operatingSystemVersionString)")
    #if arch(arm64)
    print("  arch:     arm64 ✓")
    #else
    print("  arch:     NOT arm64 ✗")
    #endif
    print("  Rosetta:  \(RosettaState.current() == .installed ? "installed ✓" : "NOT installed ✗")")
    let fm = FileManager.default
    print("  disk.img: \(fm.fileExists(atPath: Paths.diskImage.path) ? "present ✓" : "missing ✗")")
    cmdStatus()
    if let cfg = Config.load(), vmPID() != nil,
       let ip = discoverIP(mac: cfg.macAddress) {
        let (_, out) = sshCapture(ip, rosettaSmokeTest)
        print("guest x86-64 exec: \(out.contains("ROSETTA_OK") ? "OK ✓" : "FAIL ✗ (\(out.trimmingCharacters(in: .whitespacesAndNewlines)))")")
    }
}

func cmdDestroy() {
    guard Config.load() != nil || FileManager.default.fileExists(atPath: Paths.stateDir.path) else {
        note("nothing to destroy")
        return
    }
    print("This deletes the VM disk (including the Vivado install) and all state in")
    print("\(Paths.stateDir.path). The work dir is kept. Type 'yes' to confirm: ", terminator: "")
    guard readLine() == "yes" else { die("aborted") }
    if vmPID() != nil { cmdStop() }
    try? FileManager.default.removeItem(at: Paths.stateDir)
    note("destroyed")
}

// MARK: - entry point

let argv = Array(CommandLine.arguments.dropFirst())
do {
    switch argv.first {
    case "setup": try cmdSetup(Array(argv.dropFirst()))
    case "install": try cmdInstall(Array(argv.dropFirst()))
    case "vivado": cmdVivado(Array(argv.dropFirst()))
    case "run": cmdRun(Array(argv.dropFirst()))
    case "shell": cmdShell()
    case "start": cmdStart()
    case "stop": cmdStop()
    case "status": cmdStatus()
    case "doctor": cmdDoctor()
    case "destroy": cmdDestroy()
    case "__vmhost":
        let cfg = loadConfigOrDie()
        try VMHost().runForever(cfg)
    case "help", "--help", "-h", nil:
        print(usage)
    default:
        print(usage)
        exit(1)
    }
} catch {
    die("\(error.localizedDescription)")
}
