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

private func sshBaseArgs(ip: String) -> [String] {
    [
        "-i", Paths.sshKey.path,
        "-o", "UserKnownHostsFile=\(Paths.knownHosts.path)",
        "-o", "StrictHostKeyChecking=accept-new",
        "-o", "LogLevel=ERROR",
        "vivado@\(ip)",
    ]
}

/// Run `cmd` in the guest through a login shell (so /etc/profile.d is sourced).
/// tty:true allocates a pty and spawns in our own process group so the user
/// can type into prompts (AuthTokenGen, ConfigGen, vivado -mode tcl, …).
@discardableResult
func sshExec(_ ip: String, _ cmd: String, tty: Bool = false) -> Int32 {
    var args = ["-o", "ConnectTimeout=10"]
    if tty { args.append("-t") }
    args += sshBaseArgs(ip: ip)
    args += ["--", "bash", "-lc", shellQuote(cmd)]
    return tty ? runInteractive("/usr/bin/ssh", args) : run("/usr/bin/ssh", args)
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

/// Interactive login shell.
func sshInteractive(_ ip: String) -> Int32 {
    runInteractive("/usr/bin/ssh", ["-t"] + sshBaseArgs(ip: ip))
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
    # $PLATFORM expands per-process in ld.so, so ARM launcher scripts load the
    # aarch64 no-op stub and the x86-64 Vivado binaries load the real one.
    if [ -f /opt/Xilinx/udev_stub_x86_64.so ]; then export LD_PRELOAD='/opt/Xilinx/udev_stub_$PLATFORM.so'; fi
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
}
