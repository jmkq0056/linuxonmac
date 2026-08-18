import AppKit
import Foundation
import Virtualization

enum VMBuilderError: LocalizedError {
    case diskCreationFailed(String)
    case isoMissing(String)

    var errorDescription: String? {
        switch self {
        case .diskCreationFailed(let why): return "Could not create the disk image: \(why)"
        case .isoMissing(let path): return "No ISO at \(path)"
        }
    }
}

struct VMBuilder {
    var isoURL: URL?
    var shareURL: URL
    var enableRosetta: Bool

    func makeConfiguration() throws -> VZVirtualMachineConfiguration {
        let config = VZVirtualMachineConfiguration()
        config.cpuCount = Self.clampedCPUCount()
        config.memorySize = Self.clampedMemory()

        let platform = VZGenericPlatformConfiguration()
        platform.machineIdentifier = try Self.loadOrCreateMachineIdentifier()
        config.platform = platform

        let bootLoader = VZEFIBootLoader()
        bootLoader.variableStore = try Self.loadOrCreateNVRAM()
        config.bootLoader = bootLoader

        config.storageDevices = try makeStorage()
        config.networkDevices = [try Self.makeNetwork()]
        config.graphicsDevices = [try Self.makeGraphics()]
        config.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
        config.keyboards = [VZUSBKeyboardConfiguration()]
        config.audioDevices = [Self.makeAudio()]
        config.directorySharingDevices = try makeShares()
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        config.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
        config.socketDevices = [VZVirtioSocketDeviceConfiguration()]

        try config.validate()
        return config
    }

    // MARK: - Sizing

    private static func clampedCPUCount() -> Int {
        let lo = VZVirtualMachineConfiguration.minimumAllowedCPUCount
        let hi = VZVirtualMachineConfiguration.maximumAllowedCPUCount
        return min(max(Tunables.cpuCount, lo), hi)
    }

    private static func clampedMemory() -> UInt64 {
        let lo = VZVirtualMachineConfiguration.minimumAllowedMemorySize
        let hi = VZVirtualMachineConfiguration.maximumAllowedMemorySize
        return min(max(Tunables.memoryBytes, lo), hi)
    }

    // MARK: - Identity that must survive reboots

    private static func loadOrCreateMachineIdentifier() throws -> VZGenericMachineIdentifier {
        if let data = try? Data(contentsOf: Paths.machineIdentifier),
           let existing = VZGenericMachineIdentifier(dataRepresentation: data) {
            return existing
        }
        let fresh = VZGenericMachineIdentifier()
        try fresh.dataRepresentation.write(to: Paths.machineIdentifier)
        return fresh
    }

    private static func loadOrCreateNVRAM() throws -> VZEFIVariableStore {
        if FileManager.default.fileExists(atPath: Paths.nvram.path) {
            return VZEFIVariableStore(url: Paths.nvram)
        }
        return try VZEFIVariableStore(creatingVariableStoreAt: Paths.nvram)
    }

    // MARK: - Devices

    private func makeStorage() throws -> [VZStorageDeviceConfiguration] {
        try Self.createDiskIfNeeded()

        let rootAttachment = try VZDiskImageStorageDeviceAttachment(
            url: Paths.disk,
            readOnly: false,
            cachingMode: .automatic,
            synchronizationMode: .fsync
        )
        var devices: [VZStorageDeviceConfiguration] = [
            VZVirtioBlockDeviceConfiguration(attachment: rootAttachment)
        ]

        if let isoURL {
            guard FileManager.default.fileExists(atPath: isoURL.path) else {
                throw VMBuilderError.isoMissing(isoURL.path)
            }
            let iso = try VZDiskImageStorageDeviceAttachment(url: isoURL, readOnly: true)
            devices.append(VZUSBMassStorageDeviceConfiguration(attachment: iso))
        }
        return devices
    }

    private static func createDiskIfNeeded() throws {
        guard !FileManager.default.fileExists(atPath: Paths.disk.path) else { return }
        guard FileManager.default.createFile(atPath: Paths.disk.path, contents: nil) else {
            throw VMBuilderError.diskCreationFailed("could not create \(Paths.disk.path)")
        }
        let handle = try FileHandle(forWritingTo: Paths.disk)
        defer { try? handle.close() }
        try handle.truncate(atOffset: Tunables.diskSizeBytes)
        Log.info("Created a \(Tunables.diskSizeBytes / (1024 * 1024 * 1024)) GB sparse disk.")
    }

    /// The MAC has to be pinned, not generated per launch.
    ///
    /// Restoring a saved state fails with a bare "invalid argument" unless the
    /// configuration matches the one that was saved, and a random MAC guarantees
    /// it never does — so every resume silently degraded to a cold boot. It also
    /// gave the guest a new DHCP lease, and therefore a new IP, on every launch.
    private static func makeNetwork() throws -> VZVirtioNetworkDeviceConfiguration {
        let device = VZVirtioNetworkDeviceConfiguration()
        device.attachment = VZNATNetworkDeviceAttachment()
        device.macAddress = try loadOrCreateMACAddress()
        return device
    }

    private static func loadOrCreateMACAddress() throws -> VZMACAddress {
        if let stored = try? String(contentsOf: Paths.macAddress, encoding: .utf8),
           let existing = VZMACAddress(string: stored.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return existing
        }
        let fresh = VZMACAddress.randomLocallyAdministered()
        try fresh.string.write(to: Paths.macAddress, atomically: true, encoding: .utf8)
        Log.info("Assigned a persistent MAC: \(fresh.string)")
        return fresh
    }

    /// One scanout at the panel's true pixel size. Anything less is upscaled and blurry;
    /// readability is the guest's job via desktop scaling, not the host's via interpolation.
    ///
    /// Pinned for the same reason as the MAC: a scanout derived from whatever
    /// display happens to be attached would change the configuration whenever an
    /// external monitor is plugged in, breaking restore. The view reconfigures
    /// the guest's resolution live anyway, so the stored value only ever needs to
    /// be a starting point.
    private static func makeGraphics() throws -> VZVirtioGraphicsDeviceConfiguration {
        let (width, height) = try loadOrCreateScanout()
        let graphics = VZVirtioGraphicsDeviceConfiguration()
        graphics.scanouts = [
            VZVirtioGraphicsScanoutConfiguration(widthInPixels: width, heightInPixels: height)
        ]
        Log.info("Display scanout: \(width)x\(height) native pixels.")
        return graphics
    }

    private static func loadOrCreateScanout() throws -> (Int, Int) {
        if let stored = try? String(contentsOf: Paths.scanout, encoding: .utf8) {
            let parts = stored.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "x")
            if parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) {
                return (w, h)
            }
        }
        let screen = NSScreen.main ?? NSScreen.screens.first
        let scale = screen?.backingScaleFactor ?? 2.0
        let points = screen?.frame.size ?? CGSize(width: 1280, height: 832)
        let width = Int((points.width * scale).rounded())
        let height = Int((points.height * scale).rounded())
        try "\(width)x\(height)".write(to: Paths.scanout, atomically: true, encoding: .utf8)
        return (width, height)
    }

    private static func makeAudio() -> VZVirtioSoundDeviceConfiguration {
        let audio = VZVirtioSoundDeviceConfiguration()
        let output = VZVirtioSoundDeviceOutputStreamConfiguration()
        output.sink = VZHostAudioOutputStreamSink()
        let input = VZVirtioSoundDeviceInputStreamConfiguration()
        input.source = VZHostAudioInputStreamSource()
        audio.streams = [output, input]
        return audio
    }

    private func makeShares() throws -> [VZDirectorySharingDeviceConfiguration] {
        try VZVirtioFileSystemDeviceConfiguration.validateTag(Tunables.homeShareTag)
        let home = VZVirtioFileSystemDeviceConfiguration(tag: Tunables.homeShareTag)
        home.share = VZSingleDirectoryShare(
            directory: VZSharedDirectory(url: shareURL, readOnly: false)
        )
        var shares: [VZDirectorySharingDeviceConfiguration] = [home]

        if enableRosetta {
            switch VZLinuxRosettaDirectoryShare.availability {
            case .installed:
                let rosetta = VZVirtioFileSystemDeviceConfiguration(tag: Tunables.rosettaShareTag)
                rosetta.share = try VZLinuxRosettaDirectoryShare()
                shares.append(rosetta)
                Log.info("Rosetta share attached — x86_64 Linux binaries will run.")
            case .notInstalled:
                Log.warn("Rosetta is not installed. Run: softwareupdate --install-rosetta")
            case .notSupported:
                Log.warn("Rosetta is not available on this system.")
            @unknown default:
                break
            }
        }
        return shares
    }
}
