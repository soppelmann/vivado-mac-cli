import Foundation
import Virtualization

func randomMACAddress() -> String {
    VZMACAddress.randomLocallyAdministered().string
}

func newMachineIdentifierB64() -> String {
    VZGenericMachineIdentifier().dataRepresentation.base64EncodedString()
}

enum RosettaState {
    case installed, notInstalled, notSupported
    static func current() -> RosettaState {
        switch VZLinuxRosettaDirectoryShare.availability {
        case .installed: return .installed
        case .notInstalled: return .notInstalled
        case .notSupported: return .notSupported
        @unknown default: return .notSupported
        }
    }
}

/// Hosts the VZVirtualMachine. Runs as the hidden `__vmhost` subcommand in a
/// detached background process; the CLI talks to the guest over SSH.
final class VMHost: NSObject, VZVirtualMachineDelegate {
    private var vm: VZVirtualMachine!

    static func buildConfiguration(_ cfg: Config) throws -> VZVirtualMachineConfiguration {
        let c = VZVirtualMachineConfiguration()

        c.cpuCount = max(VZVirtualMachineConfiguration.minimumAllowedCPUCount,
                         min(cfg.cpus, VZVirtualMachineConfiguration.maximumAllowedCPUCount))
        let requested = UInt64(cfg.memoryGiB) << 30
        c.memorySize = max(VZVirtualMachineConfiguration.minimumAllowedMemorySize,
                           min(requested, VZVirtualMachineConfiguration.maximumAllowedMemorySize))

        let platform = VZGenericPlatformConfiguration()
        if let data = Data(base64Encoded: cfg.machineID),
           let mid = VZGenericMachineIdentifier(dataRepresentation: data) {
            platform.machineIdentifier = mid
        }
        c.platform = platform

        let efi = VZEFIBootLoader()
        if FileManager.default.fileExists(atPath: Paths.efiVars.path) {
            efi.variableStore = VZEFIVariableStore(url: Paths.efiVars)
        } else {
            efi.variableStore = try VZEFIVariableStore(creatingVariableStoreAt: Paths.efiVars)
        }
        c.bootLoader = efi

        var disks: [VZStorageDeviceConfiguration] = [
            VZVirtioBlockDeviceConfiguration(
                attachment: try VZDiskImageStorageDeviceAttachment(url: Paths.diskImage, readOnly: false))
        ]
        if FileManager.default.fileExists(atPath: Paths.seedISO.path) {
            disks.append(VZVirtioBlockDeviceConfiguration(
                attachment: try VZDiskImageStorageDeviceAttachment(url: Paths.seedISO, readOnly: true)))
        }
        c.storageDevices = disks

        let net = VZVirtioNetworkDeviceConfiguration()
        net.attachment = VZNATNetworkDeviceAttachment()
        guard let mac = VZMACAddress(string: cfg.macAddress) else {
            throw NSError(domain: "vivado-mac", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "bad MAC in config: \(cfg.macAddress)"])
        }
        net.macAddress = mac
        c.networkDevices = [net]

        c.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

        FileManager.default.createFile(atPath: Paths.consoleLog.path, contents: nil)
        if let logFH = FileHandle(forWritingAtPath: Paths.consoleLog.path) {
            logFH.seekToEndOfFile()
            let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
            serial.attachment = VZFileHandleSerialPortAttachment(
                fileHandleForReading: nil, fileHandleForWriting: logFH)
            c.serialPorts = [serial]
        }

        let work = VZVirtioFileSystemDeviceConfiguration(tag: "work")
        work.share = VZSingleDirectoryShare(
            directory: VZSharedDirectory(url: URL(fileURLWithPath: cfg.workDir), readOnly: false))
        let rosetta = VZVirtioFileSystemDeviceConfiguration(tag: "rosetta")
        rosetta.share = try VZLinuxRosettaDirectoryShare()
        c.directorySharingDevices = [work, rosetta]

        try c.validate()
        return c
    }

    func runForever(_ cfg: Config) throws -> Never {
        setsid()
        let config = try VMHost.buildConfiguration(cfg)
        try "\(getpid())\n".write(to: Paths.pidFile, atomically: true, encoding: .utf8)

        vm = VZVirtualMachine(configuration: config)
        vm.delegate = self

        // SIGTERM/SIGINT: ask the guest to power off, force-stop after 30 s.
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        for sig in [SIGTERM, SIGINT] {
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in self?.shutdown() }
            src.resume()
            signalSources.append(src)
        }

        vm.start { result in
            switch result {
            case .success:
                self.log("VM started")
            case .failure(let error):
                self.log("VM failed to start: \(error)")
                self.cleanupAndExit(1)
            }
        }
        RunLoop.main.run()
        fatalError("runloop exited")
    }

    private var signalSources: [DispatchSourceSignal] = []

    private func shutdown() {
        log("shutdown requested")
        do { try vm.requestStop() } catch {
            log("requestStop failed (\(error)); force stopping")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, self.vm.state != .stopped else { return }
            self.vm.stop { _ in self.cleanupAndExit(0) }
        }
    }

    private func log(_ msg: String) {
        FileHandle.standardError.write(("[vmhost] " + msg + "\n").data(using: .utf8)!)
    }

    private func cleanupAndExit(_ code: Int32) -> Never {
        try? FileManager.default.removeItem(at: Paths.pidFile)
        exit(code)
    }

    // MARK: VZVirtualMachineDelegate

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        log("guest powered off")
        cleanupAndExit(0)
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        log("VM stopped with error: \(error)")
        cleanupAndExit(1)
    }
}
