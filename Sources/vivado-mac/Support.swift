import Foundation

// MARK: - Paths / Config

enum Paths {
    static let stateDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".vivado-mac")
    static let configFile = stateDir.appendingPathComponent("config.json")
    static let baseImage = stateDir.appendingPathComponent("ubuntu-24.04-arm64.qcow2")
    static let diskImage = stateDir.appendingPathComponent("disk.img")
    static let efiVars = stateDir.appendingPathComponent("efi_vars.fd")
    static let seedISO = stateDir.appendingPathComponent("seed.iso")
    static let sshKey = stateDir.appendingPathComponent("id_ed25519")
    static let sshPubKey = stateDir.appendingPathComponent("id_ed25519.pub")
    static let knownHosts = stateDir.appendingPathComponent("known_hosts")
    static let pidFile = stateDir.appendingPathComponent("vm.pid")
    static let lockFile = stateDir.appendingPathComponent("vm.lock")
    static let activityLock = stateDir.appendingPathComponent("active.lock")
    static let activityStamp = stateDir.appendingPathComponent("last-activity")
    static let consoleLog = stateDir.appendingPathComponent("console.log")
    static let vmhostLog = stateDir.appendingPathComponent("vmhost.log")
}

struct Config: Codable {
    var cpus: Int
    var memoryGiB: Int
    var diskGiB: Int
    var workDir: String
    var macAddress: String
    var machineID: String // base64 VZGenericMachineIdentifier
    var idleMinutes: Int? // auto-shutdown after N idle minutes; 0 = stay resident

    var idleTimeoutMinutes: Int { idleMinutes ?? 15 }

    static func load() -> Config? {
        guard let data = try? Data(contentsOf: Paths.configFile) else { return nil }
        return try? JSONDecoder().decode(Config.self, from: data)
    }

    func save() throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: Paths.configFile)
    }
}

func die(_ msg: String) -> Never {
    FileHandle.standardError.write(("vivado-mac: " + msg + "\n").data(using: .utf8)!)
    exit(1)
}

func note(_ msg: String) {
    print("▸ " + msg)
}

// MARK: - Process helpers

@discardableResult
func run(_ tool: String, _ args: [String], quiet: Bool = false) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    if quiet {
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
    }
    do { try p.run() } catch { return -1 }
    p.waitUntilExit()
    return p.terminationStatus
}

/// Interactive spawn: unlike Foundation's Process (which puts the child in a
/// new process group, so any terminal read stops it with SIGTTIN), plain
/// posix_spawn keeps the child in our foreground process group and the
/// terminal works normally.
func runInteractive(_ tool: String, _ args: [String]) -> Int32 {
    var pid: pid_t = 0
    var argv: [UnsafeMutablePointer<CChar>?] = ([tool] + args).map { strdup($0) }
    argv.append(nil)
    defer { argv.compactMap { $0 }.forEach { free($0) } }
    let rc = posix_spawn(&pid, tool, nil, nil, &argv, environ)
    guard rc == 0 else { return -1 }
    var status: Int32 = 0
    while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
    if (status & 0x7f) == 0 { return (status >> 8) & 0xff }
    return 128 + (status & 0x7f)
}

func capture(_ tool: String, _ args: [String]) -> (status: Int32, output: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return (-1, "") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

var stdinIsTTY: Bool { isatty(0) == 1 }

// MARK: - SSH

/// Every ssh invocation pins its own options: the user's ~/.ssh/config may
/// multiplex connections (ControlMaster auto + ControlPersist), and a session
/// requested over a master that was opened without X11 forwarding silently
/// gets no DISPLAY. Agent forwarding into the guest is not wanted either.
private func sshBaseArgs(ip: String) -> [String] {
    [
        "-o", "ControlMaster=no",
        "-o", "ControlPath=none",
        "-o", "ForwardAgent=no",
        "-i", Paths.sshKey.path,
        "-o", "UserKnownHostsFile=\(Paths.knownHosts.path)",
        "-o", "StrictHostKeyChecking=accept-new",
        "-o", "LogLevel=ERROR",
        "vivado@\(ip)",
    ]
}

/// Trusted X11 forwarding into the guest (`vivado-mac gui`). Trusted (-Y), not
/// -X: untrusted forwarding runs clients under the X SECURITY extension, which
/// breaks Java AWT and GTK. XAuthLocation is pinned to XQuartz's xauth instead
/// of relying on Apple's /usr/X11R6 selector symlink. DISPLAY must be in our
/// environment before spawning (see XQuartz.resolveDisplay / requireHostX11).
let x11ForwardArgs = ["-Y", "-o", "XAuthLocation=\(XQuartz.xauthPath)"]

/// Run `cmd` in the guest through a login shell (so /etc/profile.d is sourced).
/// tty:true allocates a pty and spawns in our own process group so the user
/// can type into prompts (AuthTokenGen, ConfigGen, vivado -mode tcl, …).
/// x11:true forwards the Mac's XQuartz display into the session; such sessions
/// are long-lived and must see the terminal's Ctrl-C, so they always spawn in
/// our process group like tty sessions do.
@discardableResult
func sshExec(_ ip: String, _ cmd: String, tty: Bool = false, x11: Bool = false) -> Int32 {
    var args = ["-o", "ConnectTimeout=10"]
    if tty { args.append("-t") }
    if x11 { args += x11ForwardArgs }
    args += sshBaseArgs(ip: ip)
    args += ["--", "bash", "-lc", shellQuote(cmd)]
    return (tty || x11) ? runInteractive("/usr/bin/ssh", args) : run("/usr/bin/ssh", args)
}

func sshCapture(_ ip: String, _ cmd: String) -> (status: Int32, output: String) {
    var args = ["-o", "ConnectTimeout=10", "-o", "BatchMode=yes"]
    args += sshBaseArgs(ip: ip)
    args += ["--", "bash", "-lc", shellQuote(cmd)]
    return capture("/usr/bin/ssh", args)
}

func sshReachable(_ ip: String) -> Bool {
    var args = ["-o", "ConnectTimeout=3", "-o", "BatchMode=yes"]
    args += sshBaseArgs(ip: ip)
    args += ["--", "true"]
    return run("/usr/bin/ssh", args, quiet: true) == 0
}

/// Interactive login shell (optionally with the XQuartz display forwarded).
func sshInteractive(_ ip: String, x11: Bool = false) -> Int32 {
    runInteractive("/usr/bin/ssh", ["-t"] + (x11 ? x11ForwardArgs : []) + sshBaseArgs(ip: ip))
}

// MARK: - Guest IP discovery (macOS DHCP leases for VZNATNetworkDeviceAttachment)

/// dhcpd_leases stores MACs with leading zeros stripped per octet ("e:27:5:…").
private func normalizeMAC(_ mac: String) -> String {
    mac.lowercased().split(separator: ":").map { octet in
        let t = octet.drop(while: { $0 == "0" })
        return t.isEmpty ? "0" : String(t)
    }.joined(separator: ":")
}

private func parseLeases() -> [(ip: String, mac: String?)] {
    guard let text = try? String(contentsOfFile: "/var/db/dhcpd_leases", encoding: .utf8) else {
        return []
    }
    var entries: [(ip: String, mac: String?)] = []
    var currentIP: String?
    var currentMAC: String?
    for line in text.split(separator: "\n") {
        let l = line.trimmingCharacters(in: .whitespaces)
        if l == "{" || l == "}" {
            if l == "}" {
                if let ip = currentIP { entries.append((ip, currentMAC)) }
                currentIP = nil
                currentMAC = nil
            }
            continue
        }
        if l.hasPrefix("ip_address=") { currentIP = String(l.dropFirst("ip_address=".count)) }
        if l.hasPrefix("hw_address=1,") { currentMAC = String(l.dropFirst("hw_address=1,".count)) }
    }
    return entries
}

/// Lease IPs for our MAC first; if none match (e.g. the guest sent a DUID
/// client-id), fall back to every leased IP — a wrong VM simply fails our
/// key-based SSH auth and is skipped.
func candidateIPs(mac: String) -> [String] {
    let entries = parseLeases()
    let target = normalizeMAC(mac)
    var ips = entries.filter { $0.mac.map(normalizeMAC) == target }.map(\.ip)
    if ips.isEmpty { ips = entries.map(\.ip) }
    var seen = Set<String>()
    return ips.filter { seen.insert($0).inserted }
}

func discoverIP(mac: String) -> String? {
    candidateIPs(mac: mac).first(where: sshReachable)
}

func fileSize(_ url: URL) -> UInt64 {
    let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
    return (attrs?[.size] as? UInt64) ?? 0
}

/// Bytes actually allocated on the Mac's disk. disk.img is a sparse file, so
/// this is far below its apparent size until the guest has written that much.
func allocatedSize(_ url: URL) -> UInt64 {
    var st = stat()
    guard stat(url.path, &st) == 0 else { return 0 }
    return UInt64(max(0, st.st_blocks)) * 512
}

/// True while a __vmhost process holds the exclusive lock. The kernel releases
/// flock on any kind of process death, so this cannot go stale like a pid file.
func vmhostAlive() -> Bool {
    let fd = open(Paths.lockFile.path, O_RDWR | O_CREAT, 0o644)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    if flock(fd, LOCK_EX | LOCK_NB) == 0 {
        flock(fd, LOCK_UN)
        try? FileManager.default.removeItem(at: Paths.pidFile) // stale leftover
        return false
    }
    return true
}

private func processName(_ pid: pid_t) -> String {
    capture("/bin/ps", ["-p", "\(pid)", "-o", "comm="])
        .output.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Held (shared) by any CLI process talking to the guest, for its lifetime.
/// The vmhost probes it with an exclusive try-lock: while any client holds it,
/// the VM never counts as idle. Kernel-released on client death.
private var activityFD: Int32 = -1
func holdActivityLock() {
    guard activityFD < 0 else { return }
    activityFD = open(Paths.activityLock.path, O_RDWR | O_CREAT, 0o644)
    if activityFD >= 0 { flock(activityFD, LOCK_SH) }
    FileManager.default.createFile(atPath: Paths.activityStamp.path, contents: nil)
}

func vmPID() -> pid_t? {
    guard vmhostAlive(),
          let s = try? String(contentsOf: Paths.pidFile, encoding: .utf8),
          let pid = pid_t(s.trimmingCharacters(in: .whitespacesAndNewlines)),
          kill(pid, 0) == 0,
          processName(pid).hasSuffix("vivado-mac") else { return nil }
    return pid
}

func waitForSSH(mac: String, timeoutSeconds: Int) -> String? {
    let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
    while Date() < deadline {
        if let ip = discoverIP(mac: mac) { return ip }
        Thread.sleep(forTimeInterval: 2)
    }
    return nil
}

// MARK: - Embedded guest assets

enum Assets {
    /// cloud-init user-data. Placeholder: @@PUBKEY@@
    static let userDataTemplate = #"""
    #cloud-config
    hostname: vivado-mac
    locale: en_US.UTF-8
    users:
      - name: vivado
        groups: [sudo]
        sudo: "ALL=(ALL) NOPASSWD:ALL"
        shell: /bin/bash
        lock_passwd: true
        ssh_authorized_keys:
          - @@PUBKEY@@
    swap:
      filename: /swap.img
      size: 8589934592
      maxsize: 8589934592
    mounts:
      - [rosetta, /media/rosetta, virtiofs, "ro,nofail", "0", "0"]
      - [work, /work, virtiofs, "rw,nofail", "0", "0"]
    write_files:
      - path: /etc/apt/sources.list.d/ubuntu-amd64.sources
        content: |
          Types: deb
          URIs: http://archive.ubuntu.com/ubuntu
          Suites: noble noble-updates noble-security
          Components: main universe restricted multiverse
          Architectures: amd64
      - path: /etc/rosetta-binfmt.conf
        content: ':rosetta:M::\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x3e\x00:\xff\xff\xff\xff\xff\xfe\xfe\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:/media/rosetta/rosetta:POCF'
      - path: /etc/systemd/system/rosetta-binfmt.service
        content: |
          [Unit]
          Description=Register Rosetta 2 binfmt_misc handler for x86-64 ELF
          Requires=media-rosetta.mount
          After=media-rosetta.mount

          [Service]
          Type=oneshot
          RemainAfterExit=yes
          ExecStartPre=/bin/sh -c 'mountpoint -q /proc/sys/fs/binfmt_misc || mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc'
          ExecStart=/bin/sh -c '[ -e /proc/sys/fs/binfmt_misc/rosetta ] || cat /etc/rosetta-binfmt.conf > /proc/sys/fs/binfmt_misc/register'

          [Install]
          WantedBy=multi-user.target
      - path: /usr/local/sbin/vivado-provision.sh
        permissions: '0755'
        content: |
          #!/bin/bash
          # amd64 multiarch: the x86-64 glibc/X libraries that Rosetta-translated
          # Vivado links against (an arm64 userland has no /lib64/ld-linux-x86-64.so.2).
          # Runs from runcmd (final stage) because cloud-init rewrites
          # ubuntu.sources during the config stage and would drop the arm64 pin.
          set -euo pipefail
          grep -q '^Architectures:' /etc/apt/sources.list.d/ubuntu.sources || \
            sed -i '/^URIs:/a Architectures: arm64' /etc/apt/sources.list.d/ubuntu.sources
          dpkg --add-architecture amd64
          export DEBIAN_FRONTEND=noninteractive
          apt-get update
          apt-get install -y --no-install-recommends \
            locales unzip file ca-certificates xvfb \
            \#(guiPackages) \
            gcc-x86-64-linux-gnu:arm64 libc6-dev-amd64-cross \
            libc6:amd64 libgcc-s1:amd64 libstdc++6:amd64 zlib1g:amd64 \
            libudev1:amd64 libtinfo6:amd64 libncurses6:amd64 libexpat1:amd64 \
            libuuid1:amd64 libfreetype6:amd64 libfontconfig1:amd64 \
            libglib2.0-0t64:amd64 libnss3:amd64 libnspr4:amd64 \
            libsm6:amd64 libice6:amd64 \
            libx11-6:amd64 libxext6:amd64 libxrender1:amd64 libxtst6:amd64 \
            libxi6:amd64 libxrandr2:amd64 libxfixes3:amd64 libxft2:amd64 \
            libxcursor1:amd64 \
            libpixman-1-0:amd64 libcairo2:amd64 libpango-1.0-0:amd64 \
            libpangocairo-1.0-0:amd64 libpangoft2-1.0-0:amd64 \
            libgdk-pixbuf-2.0-0:amd64 libatk1.0-0t64:amd64 libgtk-3-0t64:amd64 \
            libxcomposite1:amd64 libxdamage1:amd64 libxinerama1:amd64 \
            libxkbcommon0:amd64 libxcb-render0:amd64 libxcb-shm0:amd64
          # arch shim: xsetup/vivado launcher scripts run under ARM bash and
          # check `uname -m`; without this they abort ("not supported on 32
          # bit platforms"). Scoped via PATH, not a global uname replacement.
          mkdir -p /opt/vivado-shim
          printf '#!/bin/sh\n[ "$1" = "-m" ] && { echo x86_64; exit 0; }\nexec /usr/bin/uname "$@"\n' > /opt/vivado-shim/uname
          printf '#!/bin/sh\necho x86_64\n' > /opt/vivado-shim/arch
          chmod +x /opt/vivado-shim/uname /opt/vivado-shim/arch
          # independent public DNS: the VZ NAT resolver (Mac's mDNSResponder,
          # possibly behind Tailscale MagicDNS) drops lookups under sustained
          # load, killing the multi-GB installer download mid-flight
          mkdir -p /etc/systemd/resolved.conf.d
          printf '[Resolve]\nDNS=1.1.1.1 8.8.8.8\nDomains=~.\n' > /etc/systemd/resolved.conf.d/public-dns.conf
          systemctl restart systemd-resolved
    runcmd:
      - systemctl daemon-reload
      - systemctl enable --now rosetta-binfmt.service
      - ln -sfn /work /home/vivado/work
      - chown -h vivado:vivado /home/vivado/work
      - /usr/local/sbin/vivado-provision.sh
    """#

    static let metaData = """
    instance-id: vivado-mac-001
    local-hostname: vivado-mac
    """

    /// NoCloud network-config: force the DHCP client-id to the MAC address.
    /// Ubuntu 24.04's networkd sends an RFC-4361 DUID by default, which makes
    /// macOS record `hw_address=ff,<duid>` in /var/db/dhcpd_leases and breaks
    /// MAC-based guest-IP discovery (same fix Lima uses).
    static let networkConfig = """
    version: 2
    ethernets:
      vmnet:
        match:
          name: "en*"
        dhcp4: true
        dhcp-identifier: mac
    """

    /// qcow2 -> raw converter, Python stdlib only. Written to the state dir and
    /// executed with the system python3 at setup time.
    static let qcow2Converter = #"""
    #!/usr/bin/env python3
    """qcow2 -> raw converter (stdlib only).

    Supports qcow2 v2/v3 with zlib-compressed clusters. No backing files, no
    encryption, no extended L2 / zstd (Ubuntu cloud images need none of those).
    Output is written sparse. Usage: qcow2_to_raw.py SRC DST [--expect-gpt]
    """
    import struct, sys, zlib

    def die(msg):
        sys.exit("qcow2_to_raw: " + msg)

    def convert(src, dst):
        f = open(src, "rb")
        hdr = f.read(104)
        if len(hdr) < 72:
            die("truncated header")
        magic, version = struct.unpack(">II", hdr[0:8])
        if magic != 0x514649FB:
            die("not a qcow2 file")
        if version not in (2, 3):
            die("unsupported qcow2 version %d" % version)
        backing_offset, = struct.unpack(">Q", hdr[8:16])
        cluster_bits, = struct.unpack(">I", hdr[20:24])
        size, = struct.unpack(">Q", hdr[24:32])
        crypt_method, = struct.unpack(">I", hdr[32:36])
        l1_size, = struct.unpack(">I", hdr[36:40])
        l1_offset, = struct.unpack(">Q", hdr[40:48])
        if backing_offset:
            die("backing files unsupported")
        if crypt_method:
            die("encrypted images unsupported")
        if version == 3:
            incompatible, = struct.unpack(">Q", hdr[72:80])
            if incompatible != 0:
                die("incompatible feature bits 0x%x unsupported" % incompatible)
        if not (9 <= cluster_bits <= 21):
            die("bad cluster_bits %d" % cluster_bits)
        cluster_size = 1 << cluster_bits
        l2_bits = cluster_bits - 3
        l2_entries = 1 << l2_bits
        f.seek(l1_offset)
        l1 = struct.unpack(">%dQ" % l1_size, f.read(8 * l1_size)) if l1_size else ()
        out = open(dst, "wb")
        out.truncate(size)
        total_clusters = (size + cluster_size - 1) >> cluster_bits
        x = 62 - (cluster_bits - 8)
        OFFSET_MASK = 0x00FFFFFFFFFFFE00
        cached_l1i, l2 = -1, None
        for ci in range(total_clusters):
            l1i, l2i = ci >> l2_bits, ci & (l2_entries - 1)
            if l1i >= len(l1):
                break
            if l1i != cached_l1i:
                l2off = l1[l1i] & OFFSET_MASK
                if l2off:
                    f.seek(l2off)
                    l2 = struct.unpack(">%dQ" % l2_entries, f.read(8 * l2_entries))
                else:
                    l2 = None
                cached_l1i = l1i
            if l2 is None:
                continue
            e = l2[l2i]
            if e & (1 << 62):  # compressed cluster
                coffset = e & ((1 << x) - 1)
                nsectors = ((e >> x) & ((1 << (62 - x)) - 1)) + 1
                csize = nsectors * 512 - (coffset & 511)
                f.seek(coffset)
                data = zlib.decompressobj(-15).decompress(f.read(csize), cluster_size)
                if len(data) < cluster_size:
                    data = data.ljust(cluster_size, b"\0")
                out.seek(ci * cluster_size)
                out.write(data)
            else:
                if e & 1:  # explicit zero cluster
                    continue
                hoff = e & OFFSET_MASK
                if not hoff:
                    continue
                f.seek(hoff)
                data = f.read(cluster_size)
                if data.rstrip(b"\0"):
                    out.seek(ci * cluster_size)
                    out.write(data)
        out.flush()
        out.close()
        return size

    def main():
        args = [a for a in sys.argv[1:] if not a.startswith("--")]
        if len(args) != 2:
            die("usage: qcow2_to_raw.py SRC DST [--expect-gpt]")
        size = convert(args[0], args[1])
        if "--expect-gpt" in sys.argv:
            rf = open(args[1], "rb")
            rf.seek(510)
            if rf.read(2) != b"\x55\xaa":
                die("converted image: protective MBR signature missing")
            rf.seek(512)
            if rf.read(8) != b"EFI PART":
                die("converted image: GPT header missing")
        print("qcow2_to_raw: OK (%d bytes)" % size)

    main()
    """#

    /// LD_PRELOAD stub: udev_enumerate_scan_devices crashes under Rosetta
    /// ("realloc(): invalid pointer"); a no-op override is the proven fix.
    static let udevStubC = """
    int udev_enumerate_scan_devices(void *e) { (void)e; return 0; }
    """

    /// Runs in the guest after xsetup Install succeeds.
    static let postInstallScript = """
    #!/bin/bash
    set -e
    # AMD's installLibs.sh ships with CRLF line endings; run it non-fatally
    f=$(find /opt/Xilinx -name installLibs.sh 2>/dev/null | head -1)
    if [ -n "$f" ]; then sudo sed -i 's/\\r$//' "$f"; sudo bash "$f" || true; fi
    # installLibs flips the cross toolchain to the broken :amd64 variants; re-pin
    sudo apt-get remove -y gcc-13-x86-64-linux-gnu:amd64 binutils-x86-64-linux-gnu:amd64 2>/dev/null || true
    sudo apt-get install -y -q gcc-x86-64-linux-gnu:arm64 binutils-x86-64-linux-gnu:arm64 libc6-dev-amd64-cross gcc >/dev/null
    # per-arch no-op udev stubs, selected at runtime via LD_PRELOAD $PLATFORM
    echo 'int udev_enumerate_scan_devices(void *e) { (void)e; return 0; }' > /tmp/udev_stub.c
    x86_64-linux-gnu-gcc -shared -fPIC -O2 /tmp/udev_stub.c -o /opt/Xilinx/udev_stub_x86_64.so
    gcc -shared -fPIC -O2 /tmp/udev_stub.c -o /opt/Xilinx/udev_stub_aarch64.so
    # AMD bundles x86-64 ncurses5/tinfo5 for Ubuntu 24 but its launcher misses them
    for lib in libncurses.so.5 libtinfo.so.5; do
      src=$(ls /opt/Xilinx/*/Vitis/lib/lnx64.o/Ubuntu/24/$lib /opt/Xilinx/*/Vivado/lib/lnx64.o/Ubuntu/24/$lib 2>/dev/null | head -1)
      [ -n "$src" ] && sudo ln -sf "$src" /usr/lib/x86_64-linux-gnu/$lib
    done
    echo POST_INSTALL_OK
    """

    /// Replaces /usr/bin/lscpu in the guest (real binary kept as lscpu.distrib).
    /// Vivado 2026.1's FeatureStore execs /usr/bin/lscpu by absolute path and
    /// std::stoi's the values; the ARM/VZ output has '-' fields and no CPU MHz
    /// lines, which throws and fails synth_design with the bare error "stoi".
    static let lscpuShim = """
    #!/bin/sh
    # vivado-mac: x86-style lscpu for Vivado's FeatureStore (real: lscpu.distrib)
    n=$(getconf _NPROCESSORS_ONLN)
    cat <<EOT
    Architecture:                    x86_64
    CPU op-mode(s):                  32-bit, 64-bit
    Byte Order:                      Little Endian
    CPU(s):                          $n
    On-line CPU(s) list:             0-$((n-1))
    Thread(s) per core:              1
    Core(s) per socket:              $n
    Socket(s):                       1
    NUMA node(s):                    1
    Vendor ID:                       GenuineIntel
    CPU family:                      6
    Model:                           142
    Model name:                      VirtualApple @ 2.50GHz
    Stepping:                        10
    CPU MHz:                         2500.000
    CPU max MHz:                     2500.0000
    CPU min MHz:                     2500.0000
    BogoMIPS:                        5000.00
    L1d cache:                       64K
    L1i cache:                       128K
    L2 cache:                        4096K
    L3 cache:                        6144K
    NUMA node0 CPU(s):               0-$((n-1))
    Flags:                           fpu tsc cx8 apic sep cmov pat pse36 clflush mmx fxsr sse sse2 syscall nx lm rep_good nopl pni pclmulqdq ssse3 cx16 sse4_1 popcnt sse4_2 aes movbe fma avx f16c rdrand bmi1 avx2 bmi2
    EOT
    """

    /// Guest packages for the GUI path (SSH X11 forwarding). All arm64 / arch-
    /// independent: `xauth` is what sshd needs to accept X11 forwarding at all
    /// (the cloud image lacks it, and sshd skips forwarding silently without it);
    /// fonts because Java AWT aborts font enumeration on a font-less system;
    /// `x11-utils` only for the xdpyinfo display test. The amd64 X client
    /// libraries Vivado itself links against are already in vivado-provision.sh.
    static let guiPackages = "xauth x11-utils fonts-dejavu-core fontconfig"

    /// Idempotent GUI provisioning for VMs created before GUI support existed
    /// (cloud-init runs only on first boot, so user-data changes never reach an
    /// existing disk). Prints GUI_PROVISION_OK on success, SSHD_X11_OFF if the
    /// guest sshd has X11Forwarding disabled (Ubuntu's default is yes).
    static var guiProvisionScript: String { """
    #!/bin/bash
    set -e
    missing=$(for p in \(guiPackages); do dpkg -s "$p" >/dev/null 2>&1 || echo "$p"; done)
    if [ -n "$missing" ]; then
      echo "installing: $(echo $missing)"
      if ! { sudo apt-get update -q && sudo DEBIAN_FRONTEND=noninteractive \
             apt-get install -y -q --no-install-recommends $missing; } >/tmp/gui-apt.log 2>&1; then
        tail -20 /tmp/gui-apt.log; echo GUI_PROVISION_FAIL; exit 1
      fi
    fi
    sudo sshd -T 2>/dev/null | grep -qi '^x11forwarding yes' || echo SSHD_X11_OFF
    command -v xauth >/dev/null && echo GUI_PROVISION_OK
    """ }

    /// Guest-side /usr/local/bin/vivado wrapper.
    static let vivadoWrapper = """
    #!/bin/bash
    # vivado-mac: run x86-64 Vivado under Rosetta with the udev-stub preload
    export PATH="/opt/vivado-shim:$PATH"
    for s in /opt/Xilinx/*/Vivado/settings64.sh /opt/Xilinx/Vivado/*/settings64.sh; do
      if [ -f "$s" ]; then source "$s"; break; fi
    done
    bin=$(ls -1 /opt/Xilinx/*/Vivado/bin/vivado /opt/Xilinx/Vivado/*/bin/vivado 2>/dev/null | head -1)
    if [ -z "$bin" ]; then echo "vivado not found under /opt/Xilinx" >&2; exit 127; fi
    # The udev stub is NOT preloaded by default: the full 2026.1 synth->bitstream
    # flow verified clean without it under Rosetta. If Vivado ever dies with
    # "realloc(): invalid pointer" (libudev under Rosetta), re-enable with:
    #   export LD_PRELOAD=/opt/Xilinx/udev_stub_x86_64.so
    if [ -n "$DISPLAY" ]; then
      # GUI over a forwarded X connection (vivado-mac gui). Java2D's pixmap
      # offscreen path round-trips pixels through the X server and is the known
      # slow path on non-local displays. Opt-in knobs if windows misbehave:
      #   export J2D_USE_MITSHM=false            # X errors mentioning shm / BadAccess
      #   export _JAVA_AWT_WM_NONREPARENTING=1   # grey or never-focused windows
      export JAVA_TOOL_OPTIONS="${JAVA_TOOL_OPTIONS:+$JAVA_TOOL_OPTIONS }-Dsun.java2d.pmoffscreen=false"
    fi
    export XILINXD_LICENSE_FILE=${XILINXD_LICENSE_FILE:-/work/Xilinx.lic}
    exec "$bin" "$@"
    """

    /// Guest-side /etc/profile.d/vivado.sh. Deliberately does NOT source
    /// settings64.sh: that prepends the real Vivado bin dir to PATH, which
    /// would shadow the /usr/local/bin/vivado wrapper and lose the Rosetta
    /// udev-stub LD_PRELOAD. Appending keeps the wrapper first for `vivado`
    /// while still exposing xsdb/updatemem/etc.
    static let profileScript = """
    # vivado-mac environment
    export PATH="/opt/vivado-shim:$PATH"
    # FORK: the JDK defaults to vfork for Runtime.exec, which breaks under
    # Rosetta (xsetup dies probing '/bin/sh -c echo $TMPDIR').
    # preferIPv4Stack: the VZ NAT is IPv4-only, but AMD's Akamai CDN resolves
    # to AAAA records — Java then fails with NoRouteToHostException.
    export JAVA_TOOL_OPTIONS="-Djdk.lang.Process.launchMechanism=FORK -Djava.net.preferIPv4Stack=true"
    export XILINXD_LICENSE_FILE=${XILINXD_LICENSE_FILE:-/work/Xilinx.lic}
    vbin=$(ls -d /opt/Xilinx/*/Vivado/bin /opt/Xilinx/Vivado/*/bin 2>/dev/null | head -1)
    if [ -n "$vbin" ]; then case ":$PATH:" in *":$vbin:"*) ;; *) PATH="$PATH:$vbin" ;; esac; fi
    unset vbin
    """

    // MARK: USB JTAG over USB/IP (see JTAG.swift)

    /// Guest side of USB/IP, idempotent and cheap to rerun. vhci-hcd lives in
    /// linux-modules-extra-<running kernel> (not in the cloud image); the usbip
    /// client comes from linux-tools-virtual, which tracks the kernel meta
    /// package. libusb is for the x86-64 hw_server. If Vivado is installed, its
    /// own cable udev rules (52-xilinx-*.rules: permissions + ftdi_sio unbind)
    /// are installed through AMD's install_drivers — this VM runs a real udev,
    /// so they fire for USB/IP-attached devices like for local ones.
    static let jtagProvisionScript = """
    #!/bin/bash
    set -e
    k=$(uname -r)
    pkgs="linux-tools-virtual linux-tools-common usbutils libusb-1.0-0:amd64 linux-modules-extra-$k"
    missing=$(for p in $pkgs; do dpkg -s "$p" >/dev/null 2>&1 || echo "$p"; done)
    if [ -n "$missing" ]; then
      echo "installing: $(echo $missing)"
      if ! { sudo apt-get update -q && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends $missing; } >/tmp/jtag-apt.log 2>&1; then
        tail -20 /tmp/jtag-apt.log
        echo "hint: if linux-modules-extra-$k is not in the archive any more, update the kernel and reboot:"
        echo "      vivado-mac run 'sudo apt-get install -y linux-virtual && sudo reboot'"
        echo JTAG_PROVISION_FAIL; exit 1
      fi
    fi
    echo vhci-hcd | sudo tee /etc/modules-load.d/vivado-mac-usbip.conf >/dev/null
    sudo modprobe vhci-hcd
    d=$(ls -d /opt/Xilinx/*/Vivado/data/xicom/cable_drivers/lin64/install_script/install_drivers 2>/dev/null | head -1)
    if [ -n "$d" ] && [ ! -f /etc/udev/rules.d/52-xilinx-pcusb.rules ]; then
      echo "installing Vivado cable udev rules (install_drivers)"
      (cd "$d" && sudo ./install_drivers) >/tmp/jtag-drivers.log 2>&1 || echo "install_drivers failed (see /tmp/jtag-drivers.log)"
      sudo udevadm control --reload 2>/dev/null || true
    fi
    command -v usbip >/dev/null && lsmod | grep -q '^vhci_hcd' && echo JTAG_PROVISION_OK
    """

    /// Attach one shared device: `attach HOST BUSID`. Prints
    /// `ATTACHED <vid:pid> <devnode>`; NEED_PROVISION if the guest lacks
    /// vhci-hcd/usbip. Drops a stale port for the same remote busid first (an
    /// attachment survives the Mac side going away as a dead port). The chmod
    /// and ftdi_sio unbind duplicate what Vivado's udev rules do, for the
    /// window before Vivado (and its rules) are installed.
    static let usbipAttachScript = """
    #!/bin/bash
    host=$1; busid=$2
    sudo modprobe vhci-hcd 2>/dev/null || { echo NEED_PROVISION; exit 2; }
    command -v usbip >/dev/null || { echo NEED_PROVISION; exit 2; }
    for port in $(sudo usbip port 2>/dev/null | awk -v s="/$busid" '/^Port /{p=$2+0} substr($0, length($0)-length(s)+1) == s {print p}'); do
      sudo usbip detach -p "$port" >/dev/null 2>&1 && echo "dropped stale port $port"
    done
    ok=
    for i in 1 2 3 4 5; do
      out=$(sudo usbip attach -r "$host" -b "$busid" 2>&1) && { ok=1; break; }
      sleep 2
    done
    [ -n "$ok" ] || { echo "$out"; echo ATTACH_FAIL; exit 1; }
    node=; vidpid=; sysfs=
    for i in $(seq 1 15); do
      sysfs=$(sudo usbip port 2>/dev/null | awk -v s="/$busid" 'substr($0, length($0)-length(s)+1) == s {print $1}' | tail -1)
      d=/sys/bus/usb/devices/$sysfs
      if [ -n "$sysfs" ] && [ -f "$d/busnum" ] && [ -f "$d/idVendor" ]; then
        node=$(printf "/dev/bus/usb/%03d/%03d" "$(cat $d/busnum)" "$(cat $d/devnum)")
        vidpid="$(cat $d/idVendor):$(cat $d/idProduct)"
        [ -e "$node" ] && break
      fi
      sleep 1
    done
    [ -n "$node" ] && [ -e "$node" ] || { echo ATTACH_NO_NODE; exit 1; }
    sudo chmod 666 "$node"
    case $vidpid in 0403:*)
      for i in 0 1; do echo -n "$sysfs:1.$i" | sudo tee /sys/bus/usb/drivers/ftdi_sio/unbind >/dev/null 2>&1; done ;;
    esac
    echo "ATTACHED $vidpid $node"
    """

    // MARK: Tcl bridge into a running Vivado GUI (see `vivado-mac tcl`)

    /// Sourced into Vivado at `vivado-mac gui` start (or by hand in the GUI's
    /// Tcl Console). Vivado has no remote Tcl of its own, and after start_gui
    /// the terminal prompt is gone until stop_gui; this listens on 127.0.0.1
    /// inside the VM and evaluates one line per request, returning the result.
    /// Only reachable through vivado-mac's ssh session. Output that a command
    /// *prints* (puts, report_* without -return_string) still goes to the GUI
    /// console; the command's return value is what comes back over the bridge.
    static let tclBridgeServer = """
    # vivado-mac Tcl bridge — lets `vivado-mac tcl` drive this session from the Mac.
    namespace eval ::vmtcl {
        variable port 8234
        variable sock
        proc accept {chan addr p} {
            fconfigure $chan -buffering line -blocking 0 -translation lf
            fileevent $chan readable [list ::vmtcl::serve $chan]
        }
        proc serve {chan} {
            if {[gets $chan line] < 0} {
                if {[eof $chan]} { catch {close $chan} }
                return
            }
            # rc 2 is TCL_RETURN: a top-level `return "x"` is a result, not an error
            set rc [catch {uplevel #0 $line} result]
            if {$rc == 0 || $rc == 2} {
                puts $chan $result
            } else {
                puts $chan "ERROR: $result"
            }
            puts $chan "<<vmtcl-end>>"
        }
        proc start {} {
            variable port
            variable sock
            if {[info exists sock]} { return }
            set sock [socket -server ::vmtcl::accept -myaddr 127.0.0.1 $port]
            puts "vivado-mac Tcl bridge listening on 127.0.0.1:$port  (from the Mac: vivado-mac tcl 'CMD', or vivado-mac tcl for a prompt)"
        }
    }
    ::vmtcl::start
    """

    /// Guest-side client: `client PORT CMD...` — one connection per command,
    /// via bash's /dev/tcp (no netcat needed). The interactive prompt lives on
    /// the Mac side (cmdTcl), which just calls this once per line.
    static let tclBridgeClient = """
    #!/bin/bash
    port=$1; shift
    if ! { exec 3<>/dev/tcp/127.0.0.1/$port; } 2>/dev/null; then
      echo "no Tcl bridge on port $port — is Vivado running? Start it with 'vivado-mac gui' (loads the bridge)," >&2
      echo "or in the GUI's Tcl Console run:  source /work/.vivado-mac/tclserver.tcl" >&2
      exit 2
    fi
    printf '%s\n' "$*" >&3
    while IFS= read -r l <&3; do
      [ "$l" = "<<vmtcl-end>>" ] && break
      printf '%s\n' "$l"
    done
    exec 3>&- 3<&-
    """

    static let usbipDetachScript = """
    #!/bin/bash
    for port in $(sudo usbip port 2>/dev/null | awk '/^Port /{print $2+0}'); do
      sudo usbip detach -p "$port" >/dev/null 2>&1 && echo "detached port $port"
    done
    echo DETACH_DONE
    """
}
