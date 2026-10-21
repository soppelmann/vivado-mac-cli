import Foundation

/// Host-side XQuartz handling for `vivado-mac gui`.
///
/// The GUI path is plain SSH X11 forwarding (`ssh -Y`) into the otherwise
/// unchanged headless VM: Vivado's Java/Swing GUI speaks X11, XQuartz is the X
/// server on the Mac, and every window lands on the macOS desktop. Nothing about
/// the VM (no graphics device, no desktop environment, no VNC) changes.
enum XQuartz {
    static let appPath = "/Applications/Utilities/XQuartz.app"
    static let xauthPath = "/opt/X11/bin/xauth"

    /// Older XQuartz builds crash `xauth` with "Abort trap: 6" on macOS 27
    /// (XQuartz/XQuartz#520) — and xauth is exactly the cookie step ssh runs for
    /// forwarding. 2.8.6 (2026-07) is also the first release with the Apple
    /// Silicon black-surface fix (#31). The 2.8.7 betas crash on 27.0.1 (#524).
    static let minimumVersion = "2.8.6"

    /// Fallback when there is no Homebrew: the project's own signed pkg.
    static let pkgVersion = "2.8.6"
    static var pkgURL: String {
        "https://github.com/XQuartz/XQuartz/releases/download/XQuartz-\(pkgVersion)/XQuartz-\(pkgVersion).pkg"
    }

    static var isInstalled: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: appPath) || fm.fileExists(atPath: xauthPath)
    }

    /// CFBundleShortVersionString of the installed app; "unknown" if only the
    /// /opt/X11 tree is present; nil when not installed.
    static func installedVersion() -> String? {
        guard isInstalled else { return nil }
        guard let data = FileManager.default.contents(atPath: appPath + "/Contents/Info.plist"),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = plist as? [String: Any],
              let v = dict["CFBundleShortVersionString"] as? String else { return "unknown" }
        return v
    }

    static func isAtLeast(_ version: String, _ minimum: String = minimumVersion) -> Bool {
        let a = version.split(separator: ".").map { Int($0) ?? -1 }
        let b = minimum.split(separator: ".").map { Int($0) ?? -1 }
        if a.isEmpty || a.contains(-1) { return false }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return true
    }

    /// Runs xauth once — catches the macOS 27 "Abort trap: 6" crash of old builds.
    static func xauthWorks() -> Bool {
        FileManager.default.fileExists(atPath: xauthPath) && run(xauthPath, ["-V"], quiet: true) == 0
    }

    // MARK: Homebrew

    static var brewPath: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.fileExists(atPath: $0) }
    }

    static var brewPrefix: String? {
        brewPath.map { URL(fileURLWithPath: $0).deletingLastPathComponent().deletingLastPathComponent().path }
    }

    /// True when the xquartz cask owns the install (Caskroom entry present).
    static func installedViaBrew() -> Bool {
        guard let prefix = brewPrefix else { return false }
        return FileManager.default.fileExists(atPath: prefix + "/Caskroom/xquartz")
    }

    /// Official steps from https://www.xquartz.org/FAQs.html (XQuartz 2.8+).
    static let manualUninstallInstructions = """
    To remove the manually installed XQuartz (official steps, xquartz.org/FAQs)
    and let Homebrew manage it instead:

      launchctl unload /Library/LaunchAgents/org.xquartz.startx.plist
      sudo launchctl unload /Library/LaunchDaemons/org.xquartz.privileged_startx.plist
      sudo rm -rf /opt/X11* /Library/Launch*/org.xquartz.* /Applications/Utilities/XQuartz.app /etc/*paths.d/*XQuartz
      sudo pkgutil --forget org.xquartz.X11
      brew install --cask xquartz

    then log out and back in (launchd sets DISPLAY at login) and rerun `vivado-mac gui-setup`.
    """

    // MARK: Display / process

    /// DISPLAY for the ssh client. launchd exports it to login sessions once
    /// XQuartz is installed and the user has logged in again; before that we
    /// find the launchd socket ourselves (connecting to it auto-starts XQuartz).
    static func resolveDisplay() -> String? {
        if let d = ProcessInfo.processInfo.environment["DISPLAY"], !d.isEmpty { return d }
        let (s, out) = capture("/bin/launchctl", ["getenv", "DISPLAY"])
        let d = out.trimmingCharacters(in: .whitespacesAndNewlines)
        if s == 0, !d.isEmpty { return d }
        let fm = FileManager.default
        for entry in (try? fm.contentsOfDirectory(atPath: "/private/tmp")) ?? []
        where entry.hasPrefix("com.apple.launchd.") {
            let sock = "/private/tmp/\(entry)/org.xquartz:0"
            if fm.fileExists(atPath: sock) { return sock }
        }
        return nil
    }

    /// Start XQuartz in the background if it isn't running. The launchd socket
    /// would start it on the first X connection anyway; this just removes that
    /// delay from the first window.
    static func ensureRunning() {
        if run("/usr/bin/pgrep", ["-qix", "xquartz"], quiet: true) != 0 {
            run("/usr/bin/open", ["-ga", "XQuartz"], quiet: true)
        }
    }

    /// One-line state for `status` / `doctor`.
    static func summary() -> String {
        guard let v = installedVersion() else { return "XQuartz not installed (run `vivado-mac gui-setup`)" }
        let source = installedViaBrew() ? "Homebrew" : "manual install"
        if !isAtLeast(v) { return "XQuartz \(v) (\(source)) ✗ too old — need ≥ \(minimumVersion)" }
        if !xauthWorks() { return "XQuartz \(v) (\(source)) ✗ xauth crashes — reinstall" }
        let display = resolveDisplay() == nil ? "DISPLAY unset ✗ (log out and back in)" : "DISPLAY ok"
        return "XQuartz \(v) (\(source)) ✓, \(display)"
    }

    // MARK: Install

    /// Install or upgrade XQuartz to a usable version. Homebrew is preferred
    /// (`brew install --cask xquartz`, currently 2.8.6, auto-updating); the pkg
    /// from the XQuartz GitHub release is used only when Homebrew is absent.
    /// Returns false — after printing what to do — when it cannot proceed.
    static func install(assumeYes: Bool) -> Bool {
        let current = installedVersion()
        let viaBrew = installedViaBrew()

        if let v = current, !viaBrew, brewPath != nil {
            // A manual install that is too old/broken (that's why we're here):
            // Homebrew refuses to install over a foreign XQuartz.app / /opt/X11.
            print("""

            XQuartz \(v) is installed manually (not via Homebrew) and is \(isAtLeast(v) ? "broken (xauth crashes)" : "too old (need ≥ \(minimumVersion))").
            Homebrew cannot install over it.
            \(manualUninstallInstructions)
            """)
            return false
        }

        if let brew = brewPath {
            let verb = viaBrew ? "upgrade" : "install"
            if !assumeYes {
                print("Run `brew \(verb) --cask xquartz` now (asks for your password for the installer)? [y/N] ", terminator: "")
                guard let a = readLine(), a.lowercased().hasPrefix("y") else { return false }
            }
            note("brew \(verb) --cask xquartz …")
            let rc = runInteractive(brew, [verb, "--cask", "xquartz"])
            guard rc == 0 else {
                print("""

                Homebrew failed to \(verb) the xquartz cask (exit \(rc)).
                If the error above mentions an existing XQuartz.app or /opt/X11, a manual
                install is in the way:
                \(manualUninstallInstructions)
                Otherwise fix the Homebrew error and rerun `vivado-mac gui-setup`.
                """)
                return false
            }
        } else {
            guard installFromPkg(assumeYes: assumeYes) else { return false }
        }

        guard let v = installedVersion() else {
            print("XQuartz install finished but \(appPath) is missing — reinstall manually")
            return false
        }
        guard isAtLeast(v) else {
            print("XQuartz \(v) is installed but \(minimumVersion) or newer is required (brew update && brew upgrade --cask xquartz)")
            return false
        }
        guard xauthWorks() else {
            print("""
            XQuartz \(v) is installed but \(xauthPath) crashes on this macOS. This is the
            XQuartz/XQuartz#520 failure of older builds on macOS 27; if you see it with
            \(minimumVersion) or newer, report it there and try the current stable release.
            """)
            return false
        }
        note("XQuartz \(v) ✓")
        if ProcessInfo.processInfo.environment["DISPLAY"] == nil {
            note("log out and back in once so new terminals get DISPLAY (vivado-mac itself finds the display without it)")
        }
        return true
    }

    /// No Homebrew: download the release pkg, verify its published SHA-256, install.
    private static func installFromPkg(assumeYes: Bool) -> Bool {
        if !assumeYes {
            print("No Homebrew found. Download XQuartz \(pkgVersion) (~120 MB) from the XQuartz GitHub release and install it with sudo? [y/N] ", terminator: "")
            guard let a = readLine(), a.lowercased().hasPrefix("y") else {
                print("Alternatively install Homebrew (https://brew.sh) and rerun `vivado-mac gui-setup`.")
                return false
            }
        }
        try? FileManager.default.createDirectory(at: Paths.stateDir, withIntermediateDirectories: true)
        let pkg = Paths.stateDir.appendingPathComponent("XQuartz-\(pkgVersion).pkg")
        note("downloading \(pkgURL) …")
        guard run("/usr/bin/curl", ["-fL", "--progress-bar", "-o", pkg.path, pkgURL]) == 0 else {
            print("download failed"); return false
        }
        note("verifying SHA256 …")
        let (s1, sums) = capture("/usr/bin/curl", ["-fsSL", pkgURL + ".sha256sum"])
        guard s1 == 0, let expected = sums.split(separator: " ").first, expected.count == 64 else {
            print("could not fetch the published checksum"); return false
        }
        let (s2, out) = capture("/usr/bin/shasum", ["-a", "256", pkg.path])
        guard s2 == 0, out.hasPrefix(String(expected)) else {
            try? FileManager.default.removeItem(at: pkg)
            print("SHA256 mismatch for the downloaded pkg — not installing"); return false
        }
        note("installing (sudo installer) …")
        guard runInteractive("/usr/bin/sudo", ["/usr/sbin/installer", "-pkg", pkg.path, "-target", "/"]) == 0 else {
            print("installer failed"); return false
        }
        try? FileManager.default.removeItem(at: pkg)
        return true
    }
}
