import CryptoKit
import Foundation
import IOKit
import IOKit.usb
import IOUSBHost

/// USB JTAG cables for the guest, over USB/IP.
///
/// Virtualization.framework has no USB passthrough. Instead the cable is shared
/// from the Mac by usbipd-mac (beriberikix, MIT) — a pure-Swift USB/IP server
/// that drives the device from userspace through IOKit: no root, no kernel or
/// system extension, nothing to install system-wide — and imported in the
/// guest by the kernel's vhci-hcd driver with the standard `usbip` client, so
/// Vivado's hw_server sees an ordinary USB device. The approach and the two
/// usbipd-mac fixes it needs (UsbipdPatch.swift) come from tae2yi/vivado-on-mac
/// (CC0), where they were verified with a Platform Cable USB II on Vivado 2026.1.
///
/// Flow: `usbipd list` → find a cable by vendor ID → `usbipd bind` (with the
/// two recoveries macOS needs) → guest `usbip attach -r <NAT gateway>` → the
/// guest's udev applies Vivado's cable rules → hw_server. A Platform Cable
/// enumerates as 03fd:0013 until hw_server loads its firmware, then comes back
/// as 03fd:0008 and has to be shared again — that dance is automated below.
enum JTAG {
    /// Vendor IDs covered by Vivado's own cable rules (52-xilinx-*.rules).
    static let vendorIDs: [String: String] = [
        "03fd": "Xilinx Platform Cable USB / USB II",
        "0403": "FTDI-based cable (Xilinx / Digilent on-board JTAG)",
        "1443": "Digilent",
    ]
    static let usbipdRepo = "https://github.com/beriberikix/usbipd-mac"
    /// The commit UsbipdPatch was written against.
    static let usbipdCommit = "1c2ab4594653db5859d6773bdd010303a641e98e"
    static let port = 3240
    static let firmwareTimeoutSeconds = 90

    static var srcDir: URL { Paths.stateDir.appendingPathComponent("usbipd-mac") }
    static var binary: URL { srcDir.appendingPathComponent(".build/release/usbipd") }
    static var buildStamp: URL { srcDir.appendingPathComponent(".vivado-mac-build") }
    static var patchFile: URL { Paths.stateDir.appendingPathComponent("usbipd-mac.patch") }
    static var daemonLog: URL { Paths.stateDir.appendingPathComponent("usbipd.log") }

    struct Device {
        let busid: String
        let vid: String
        let pid: String
        let name: String
        var vidpid: String { "\(vid):\(pid)" }
        var isUnprogrammedPlatformCable: Bool { vidpid == "03fd:0013" }
    }

    // MARK: usbipd-mac build

    /// Identifies what the binary was built from; a changed patch rebuilds.
    static var stampValue: String {
        let digest = SHA256.hash(data: Data(UsbipdPatch.text.utf8)).map { String(format: "%02x", $0) }.joined()
        return "\(usbipdCommit)+\(digest)"
    }

    static var isBuilt: Bool {
        FileManager.default.isExecutableFile(atPath: binary.path)
            && (try? String(contentsOf: buildStamp, encoding: .utf8)) == stampValue
    }

    @discardableResult
    private static func git(_ args: [String], quiet: Bool = true) -> Int32 {
        run("/usr/bin/git", ["-C", srcDir.path] + args, quiet: quiet)
    }

    /// Clone usbipd-mac at the pinned commit, apply the fixes, build. Idempotent;
    /// a no-op once the stamp matches.
    static func ensureBuilt() -> Bool {
        let fm = FileManager.default
        if isBuilt { return true }
        try? fm.createDirectory(at: Paths.stateDir, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: srcDir.appendingPathComponent(".git").path) {
            note("downloading usbipd-mac (USB/IP server for macOS, pure Swift) …")
            guard run("/usr/bin/git", ["clone", "-q", usbipdRepo, srcDir.path]) == 0 else {
                print("git clone failed — check the network and retry")
                return false
            }
        }
        if git(["checkout", "-q", usbipdCommit]) != 0 {
            git(["fetch", "-q", "origin"])
            guard git(["checkout", "-q", usbipdCommit]) == 0 else {
                print("could not check out usbipd-mac \(usbipdCommit.prefix(12)) — delete \(srcDir.path) and retry")
                return false
            }
        }
        try? UsbipdPatch.text.write(to: patchFile, atomically: true, encoding: .utf8)
        if git(["apply", "--reverse", "--check", patchFile.path]) != 0 {
            note("applying the vivado-on-mac fixes to usbipd-mac …")
            guard git(["apply", "--check", patchFile.path]) == 0, git(["apply", patchFile.path]) == 0 else {
                print("the usbipd-mac patch does not apply cleanly — delete \(srcDir.path) and retry")
                return false
            }
        }
        note("building usbipd-mac (swift build -c release; a few minutes the first time) …")
        var rc = run("/usr/bin/swift", ["build", "-c", "release", "--package-path", srcDir.path])
        if rc != 0 {
            // Swift's module cache records absolute paths; a cache from a moved
            // or copied checkout fails with "PCH was compiled with module cache path …".
            let build = srcDir.appendingPathComponent(".build")
            for triple in (try? fm.contentsOfDirectory(atPath: build.path)) ?? [] {
                try? fm.removeItem(at: build.appendingPathComponent(triple).appendingPathComponent("release/ModuleCache"))
            }
            note("retrying with a fresh module cache …")
            rc = run("/usr/bin/swift", ["build", "-c", "release", "--package-path", srcDir.path])
        }
        guard rc == 0, fm.isExecutableFile(atPath: binary.path) else {
            print("usbipd-mac build failed (see above)")
            return false
        }
        try? stampValue.write(to: buildStamp, atomically: true, encoding: .utf8)
        note("usbipd-mac built: \(binary.path)")
        return true
    }

    // MARK: Devices

    /// stdout+stderr of a tool, merged (usbipd prints its refusals on stdout
    /// and the thrown error on stderr; we need both).
    private static func captureAll(_ tool: String, _ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    /// `usbipd list` rows: "<bus>-<dev>  /dev/bus/usb/<bus>/<dev>  vvvv:pppp (name)".
    static func listDevices() -> [Device] {
        let (s, out) = capture(binary.path, ["list"])
        guard s == 0 else { return [] }
        let re = try! NSRegularExpression(pattern: #"^\s*(\d+-[\d.]+)\s+\S+\s+(?:0x)?([0-9a-fA-F]{4}):(?:0x)?([0-9a-fA-F]{4})\s*(.*)$"#)
        return out.split(separator: "\n").compactMap { line -> Device? in
            let l = String(line)
            guard let m = re.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)) else { return nil }
            func group(_ i: Int) -> String { Range(m.range(at: i), in: l).map { String(l[$0]) } ?? "" }
            return Device(busid: group(1), vid: group(2).lowercased(), pid: group(3).lowercased(),
                          name: group(4).trimmingCharacters(in: .whitespaces))
        }
    }

    static func findCable(busid: String?) -> Device? {
        let devices = listDevices()
        if let b = busid { return devices.first { $0.busid == b } }
        return devices.first { vendorIDs[$0.vid] != nil }
    }

    // MARK: Daemon

    static func daemonPID() -> pid_t? {
        let (s, out) = capture("/usr/bin/pgrep", ["-f", "\(binary.path) daemon"])
        guard s == 0, let first = out.split(separator: "\n").first,
              let pid = pid_t(first.trimmingCharacters(in: .whitespaces)) else { return nil }
        return pid
    }

    static func portOpen() -> Bool {
        run("/usr/bin/nc", ["-z", "localhost", "\(port)"], quiet: true) == 0
    }

    /// usbipd needs no root: port 3240 is unprivileged and macOS lets a normal
    /// user open USB devices no kernel driver has claimed. Spawned detached
    /// (Foundation puts it in its own process group), logging to usbipd.log.
    static func startDaemon() -> Bool {
        if daemonPID() != nil, portOpen() { return true }
        note("starting the USB/IP daemon (usbipd daemon, port \(port); log: \(daemonLog.path)) …")
        FileManager.default.createFile(atPath: daemonLog.path, contents: nil)
        let log = FileHandle(forWritingAtPath: daemonLog.path)
        log?.seekToEndOfFile()
        let p = Process()
        p.executableURL = binary
        p.arguments = ["daemon"]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = log ?? FileHandle.nullDevice
        p.standardError = log ?? FileHandle.nullDevice
        do { try p.run() } catch {
            print("could not start usbipd: \(error.localizedDescription)")
            return false
        }
        for _ in 0..<30 {
            if portOpen() { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        print("usbipd did not open port \(port) — see \(daemonLog.path). (macOS may have asked whether to allow incoming connections for usbipd: allow it.)")
        return false
    }

    static func stopDaemon() {
        guard let pid = daemonPID() else { return }
        kill(pid, SIGTERM)
        for _ in 0..<40 where kill(pid, 0) == 0 { Thread.sleep(forTimeInterval: 0.25) }
        if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
    }

    /// True when our own daemon is the process holding the device's interface
    /// open (left over from an earlier attachment, e.g. before a re-enumeration
    /// or after the VM went away).
    static func daemonHoldsDevice(_ pid: pid_t) -> Bool {
        capture("/usr/sbin/ioreg", ["-r", "-c", "IOUSBHostInterface", "-l", "-w0"]).output
            .contains("\"IOUserClientCreator\" = \"pid \(pid), usbipd\"")
    }

    /// Share a device, working around the two states a cable gets into on macOS.
    /// `guestIP` lets us stop hw_server before a daemon restart drops the cable.
    static func bind(_ dev: Device, guestIP: String?) -> Bool {
        var (s, out) = captureAll(binary.path, ["bind", dev.busid])
        if s != 0, out.contains("exposes no USB interfaces") {
            // macOS sets no configuration on a vendor-class device it has no
            // driver for (an unprogrammed Platform Cable). Selecting the first
            // configuration is what any OS does on enumeration; nothing persists.
            note("macOS left \(dev.vidpid) unconfigured (normal for an unprogrammed Platform Cable) — selecting its USB configuration …")
            do {
                note(try selectConfiguration(vid: dev.vid, pid: dev.pid))
            } catch {
                print("could not select a configuration on \(dev.vidpid): \(error.localizedDescription)")
                return false
            }
            Thread.sleep(forTimeInterval: 1)
            (s, out) = captureAll(binary.path, ["bind", dev.busid])
        }
        if s != 0, out.contains("another process has it open"), let pid = daemonPID(), daemonHoldsDevice(pid) {
            note("the USB/IP daemon still holds \(dev.vidpid) from an earlier attachment — restarting it …")
            if let ip = guestIP { stopHWServer(ip) }
            stopDaemon()
            guard startDaemon() else { return false }
            (s, out) = captureAll(binary.path, ["bind", dev.busid])
        }
        guard s == 0 else {
            print(out.trimmingCharacters(in: .whitespacesAndNewlines))
            return false
        }
        return true
    }

    static func unbind(_ busid: String) {
        _ = captureAll(binary.path, ["unbind", busid])
    }

    /// Select a USB configuration on a device macOS left unconfigured, through
    /// IOUSBHost from userspace (what tae2yi does with libusb + Python).
    static func selectConfiguration(vid: String, pid: String) throws -> String {
        func fail(_ msg: String) -> NSError {
            NSError(domain: "vivado-mac.usb", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        guard let v = Int(vid, radix: 16), let p = Int(pid, radix: 16) else { throw fail("bad vid/pid") }
        let matching = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary
        matching[kUSBVendorID] = v
        matching[kUSBProductID] = p
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            throw fail("IOServiceGetMatchingServices failed")
        }
        defer { IOObjectRelease(iterator) }
        let service = IOIteratorNext(iterator)
        guard service != 0 else { throw fail("device \(vid):\(pid) not found in IOKit") }
        defer { IOObjectRelease(service) }
        let device = try IOUSBHostDevice(__ioService: service, options: [], queue: nil, interestHandler: nil)
        defer { device.destroy() }
        if device.configurationDescriptor != nil { return "device is already configured" }
        let descriptor = try device.configurationDescriptor(with: 0)
        let value = Int(descriptor.pointee.bConfigurationValue)
        try device.__configure(withValue: value, matchInterfaces: false)
        return "selected USB configuration \(value)"
    }

    // MARK: Guest side

    /// The Mac as seen from the guest: the VZ NAT gateway.
    static func hostAddressFromGuest(_ ip: String) -> String? {
        let gw = sshCapture(ip, "ip -4 route show default | awk '{print $3; exit}'").output
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return gw.isEmpty ? nil : gw
    }

    static func provisionGuest(_ ip: String) -> Bool {
        let (_, out) = sshCapture(ip, "echo \(b64(Assets.jtagProvisionScript)) | base64 -d | bash")
        guard out.contains("JTAG_PROVISION_OK") else {
            print(out.trimmingCharacters(in: .whitespacesAndNewlines))
            return false
        }
        return true
    }

    enum AttachResult {
        case attached(vidpid: String, node: String)
        case needProvision
        case failed(String)
    }

    static func attachInGuest(_ ip: String, host: String, busid: String) -> AttachResult {
        let cmd = "echo \(b64(Assets.usbipAttachScript)) | base64 -d | bash -s -- \(shellQuote(host)) \(shellQuote(busid))"
        let (_, out) = sshCapture(ip, cmd)
        if out.contains("NEED_PROVISION") { return .needProvision }
        for line in out.split(separator: "\n") where line.hasPrefix("ATTACHED ") {
            let parts = line.split(separator: " ")
            if parts.count >= 3 { return .attached(vidpid: String(parts[1]), node: String(parts[2])) }
        }
        return .failed(out.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func detachAllInGuest(_ ip: String) {
        let (_, out) = sshCapture(ip, "echo \(b64(Assets.usbipDetachScript)) | base64 -d | bash")
        for line in out.split(separator: "\n") where line.hasPrefix("detached") { note(String(line)) }
    }

    /// hw_server (x86-64, under Rosetta) on its default port 3121, started the
    /// way Vivado's Auto Connect would, so Auto Connect joins a server that
    /// already sees the cable instead of launching its own mid-reattach
    /// ("[Xicom 50-198] Cannot support out-of-date hw_server").
    static func startHWServer(_ ip: String) -> Bool {
        let (_, out) = sshCapture(ip,
            "pgrep -x hw_server >/dev/null && echo HW_OK || { command -v hw_server >/dev/null || { echo NO_HW_SERVER; exit 0; }; " +
            "(cd /tmp && setsid nohup hw_server >/tmp/hw_server.log 2>&1 </dev/null &); sleep 3; pgrep -x hw_server >/dev/null && echo HW_OK; }")
        if out.contains("NO_HW_SERVER") {
            note("hw_server not found (Vivado not installed yet) — the cable is attached; Vivado will start its own hw_server later")
            return false
        }
        return out.contains("HW_OK")
    }

    static func stopHWServer(_ ip: String) {
        if sshCapture(ip, "pgrep -x hw_server >/dev/null && echo RUNNING").output.contains("RUNNING") {
            note("stopping hw_server first (it must not be talking to the cable while it is re-attached) …")
            _ = sshExec(ip, "pkill -x hw_server; sleep 2")
        }
    }

    /// hw_server only scans for cables — and so only loads a Platform Cable's
    /// firmware — once a client asks it for JTAG targets. xsdb is that client.
    static func pokeHWServer(_ ip: String) {
        _ = sshExec(ip, "printf 'connect -url tcp:localhost:3121\\njtag targets\\nafter 5000\\n' > /tmp/jtag_poke.tcl && " +
            "(setsid nohup xsdb /tmp/jtag_poke.tcl >/dev/null 2>&1 </dev/null &)")
    }

    /// Wait for an unprogrammed Platform Cable (03fd:0013) to come back as 0008.
    /// The firmware load re-enumerates it twice a few seconds apart, so only a
    /// 0008 that stays put for 8 s counts.
    static func waitForFirmware(_ ip: String) -> Bool {
        var stable = 0
        for i in 0..<firmwareTimeoutSeconds {
            if listDevices().contains(where: { $0.vidpid == "03fd:0008" }) { stable += 1 } else { stable = 0 }
            if stable >= 8 {
                print("")
                return true
            }
            if i % 30 == 0, stable == 0 { pokeHWServer(ip) }
            let state = stable > 0 ? "firmware loaded, checking it stays put (\(stable)/8)" : "loading firmware"
            print("\r\u{1B}[K⏳ \(i)s  \(state) …", terminator: "")
            fflush(stdout)
            Thread.sleep(forTimeInterval: 1)
        }
        print("")
        return false
    }

    static func guestPorts(_ ip: String) -> String {
        sshCapture(ip, "sudo usbip port 2>/dev/null | grep -v '^Imported\\|^====' ; true").output
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - vivado-mac jtag …

func cmdJTAG(_ args: [String]) {
    let (flags, positional) = parseFlags(args, valueFlags: ["--busid"])
    switch positional.first ?? "status" {
    case "attach": jtagAttach(busid: flags["--busid"])
    case "detach": jtagDetach(stopDaemon: flags["--stop"] != nil)
    case "status": jtagStatus()
    case "list":
        guard JTAG.ensureBuilt() else { exit(1) }
        exit(run(JTAG.binary.path, ["list"]))
    case "setup": jtagSetup()
    default:
        die("usage: vivado-mac jtag attach [--busid B] | detach [--stop] | status | list | setup")
    }
}

func jtagSetup() {
    guard JTAG.ensureBuilt() else { die("usbipd-mac is not available — see above") }
    guard let cfg = Config.load() else {
        note("VM not set up yet — run `vivado-mac setup`, then `vivado-mac jtag setup` again for the guest side")
        return
    }
    let ip = ensureRunning(cfg)
    note("guest: usbip client, vhci-hcd module, cable udev rules …")
    guard JTAG.provisionGuest(ip) else { die("guest USB/IP provisioning failed") }
    note("guest ready for USB/IP")
    print("\nNext: plug in the JTAG cable and run `vivado-mac jtag attach`")
}

func jtagAttach(busid: String?) {
    let cfg = loadConfigOrDie()
    guard JTAG.ensureBuilt() else { die("usbipd-mac is not available — see above") }

    guard let cable = JTAG.findCable(busid: busid) else {
        let devices = JTAG.listDevices()
        print(devices.isEmpty ? "(usbipd sees no USB devices)" :
              devices.map { "  \($0.busid)  \($0.vidpid)  \($0.name)" }.joined(separator: "\n"))
        die("""
        no JTAG cable found (looking for vendor IDs \(JTAG.vendorIDs.keys.sorted().joined(separator: ", "))).
        Plug the cable or board into the Mac and retry, or pick one of the devices above
        with `vivado-mac jtag attach --busid <busid>`.
        """)
    }
    let kind = JTAG.vendorIDs[cable.vid] ?? "device"
    note("found \(kind): \(cable.vidpid) \(cable.name) at busid \(cable.busid)" +
         (cable.isUnprogrammedPlatformCable ? " (no firmware yet)" : ""))

    guard JTAG.startDaemon() else { exit(1) }
    let ip = ensureRunning(cfg)
    guard JTAG.bind(cable, guestIP: ip) else { die("could not share \(cable.busid) — usbipd's message is above") }
    note("cable shared over USB/IP")

    guard let host = JTAG.hostAddressFromGuest(ip) else { die("could not determine the Mac's address from the guest") }

    func attach(_ dev: JTAG.Device) -> (vidpid: String, node: String) {
        var result = JTAG.attachInGuest(ip, host: host, busid: dev.busid)
        if case .needProvision = result {
            note("guest: installing usbip client + vhci-hcd module (one-time) …")
            guard JTAG.provisionGuest(ip) else { die("guest USB/IP provisioning failed") }
            result = JTAG.attachInGuest(ip, host: host, busid: dev.busid)
        }
        switch result {
        case .attached(let vidpid, let node):
            return (vidpid, node)
        case .needProvision:
            die("guest still lacks usbip/vhci-hcd after provisioning")
        case .failed(let out):
            die("could not attach \(dev.busid) in the guest:\n\(out)")
        }
    }

    note("attaching in the guest (usbip attach -r \(host) -b \(cable.busid)) …")
    var attached = attach(cable)
    note("attached in guest: \(attached.vidpid) at \(attached.node)")
    // Keep Vivado's udev rules current (cheap, idempotent) now that something is attached.
    _ = JTAG.provisionGuest(ip)

    if attached.vidpid == "03fd:0013" {
        _ = JTAG.startHWServer(ip)
        note("the cable has no firmware yet; hw_server is loading it (~30 s). Do NOT press Auto Connect in Vivado yet.")
        guard JTAG.waitForFirmware(ip) else {
            die("""
            the cable did not come back as 03fd:0008 within \(JTAG.firmwareTimeoutSeconds) s.
            Run `vivado-mac jtag attach` again; if it keeps failing, unplug the cable (or its
            USB adapter) at the Mac, plug it back in, and retry.
            """)
        }
        note("firmware loaded: the cable is now 03fd:0008 — re-sharing it with its new identity …")
        JTAG.stopHWServer(ip)
        guard let reborn = JTAG.findCable(busid: nil), reborn.vidpid == "03fd:0008" else {
            die("lost track of the cable after its firmware load — run `vivado-mac jtag attach` again")
        }
        guard JTAG.bind(reborn, guestIP: ip) else { die("could not re-share \(reborn.busid)") }
        attached = attach(reborn)
        note("attached in guest: \(attached.vidpid) at \(attached.node)")
    }

    let hw = JTAG.startHWServer(ip)
    print("""

    ✅ JTAG cable connected to the guest (\(attached.vidpid) at \(attached.node)).
       \(hw ? "hw_server is running on localhost:3121 inside the VM." : "")
       In Vivado: Hardware Manager → Open Target → Auto Connect.
       Done with the board:  vivado-mac jtag detach   (returns the cable to macOS)
    """)
}

func jtagDetach(stopDaemon: Bool) {
    guard JTAG.isBuilt else {
        note("usbipd-mac was never built — nothing is shared")
        return
    }
    if let cfg = Config.load(), vmPID() != nil, let ip = discoverIP(mac: cfg.macAddress) {
        JTAG.stopHWServer(ip)
        JTAG.detachAllInGuest(ip)
    }
    for dev in JTAG.listDevices() where JTAG.vendorIDs[dev.vid] != nil {
        JTAG.unbind(dev.busid)
        note("unbound \(dev.busid) (\(dev.vidpid))")
    }
    if stopDaemon {
        JTAG.stopDaemon()
        note("usbipd daemon stopped")
    }
    note("detached")
}

func jtagStatus() {
    print("usbipd:   \(JTAG.isBuilt ? "built (\(JTAG.binary.path))" : "not built (vivado-mac jtag setup)")")
    guard JTAG.isBuilt else { return }
    if let pid = JTAG.daemonPID() {
        print("daemon:   running (pid \(pid), port \(JTAG.port) \(JTAG.portOpen() ? "open" : "NOT open"))")
    } else {
        print("daemon:   not running (started on demand by `jtag attach`)")
    }
    let cables = JTAG.listDevices().filter { JTAG.vendorIDs[$0.vid] != nil }
    if cables.isEmpty {
        print("cable:    none found on the Mac (vendor IDs \(JTAG.vendorIDs.keys.sorted().joined(separator: ", ")))")
    } else {
        for c in cables { print("cable:    \(c.busid)  \(c.vidpid)  \(c.name)") }
    }
    guard let cfg = Config.load(), vmPID() != nil, let ip = discoverIP(mac: cfg.macAddress) else {
        print("guest:    VM not running")
        return
    }
    let ports = JTAG.guestPorts(ip)
    print("guest:    \(ports.isEmpty ? "nothing attached" : "\n" + ports.split(separator: "\n").map { "          " + $0 }.joined(separator: "\n"))")
    let hw = sshCapture(ip, "pgrep -x hw_server >/dev/null && echo yes").output.contains("yes")
    print("hw_server: \(hw ? "running" : "not running")")
}
