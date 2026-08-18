import Foundation
import Virtualization

/// Machine properties the user does not get to move.
enum VMConstants {
    /// Sparse — it only consumes what the guest actually writes. Fixed at
    /// creation: making it bigger later would also need the guest's partition
    /// table and filesystem grown to match, which is not something a slider in
    /// the host app can do.
    static let defaultDiskSizeBytes: UInt64 = 96 * 1024 * 1024 * 1024

    static let homeShareTag = "home"
    static let rosettaShareTag = "rosetta"

    /// The size the image was actually created at, which is what the guest sees.
    /// Falls back to the default only when no image exists yet.
    static var diskSizeBytes: UInt64 {
        let values = try? Paths.disk.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values?.fileSize, size > 0 else { return defaultDiskSizeBytes }
        return UInt64(size)
    }
}

/// What this Mac and Virtualization.framework will actually allow.
enum HostLimits {
    private static let gigabyte: UInt64 = 1024 * 1024 * 1024

    /// macOS still has to run — WindowServer composites the guest's own display,
    /// and the page cache backs the disk image the guest is writing to. Handing
    /// the guest everything makes the host swap, and swapping costs far more
    /// than the extra gigabytes buy back.
    static let reservedForHostGB = 6

    static let physicalMemoryGB = Int(ProcessInfo.processInfo.physicalMemory / gigabyte)
    static let coreCount = ProcessInfo.processInfo.processorCount

    static let memoryRangeGB: ClosedRange<Int> = {
        // Round the framework floor up: half a gigabyte short of the minimum is
        // still below the minimum.
        let frameworkFloor = Int(
            (VZVirtualMachineConfiguration.minimumAllowedMemorySize + gigabyte - 1) / gigabyte
        )
        let frameworkCeiling = Int(VZVirtualMachineConfiguration.maximumAllowedMemorySize / gigabyte)
        let lowest = max(1, frameworkFloor)
        let highest = max(lowest, min(frameworkCeiling, physicalMemoryGB - reservedForHostGB))
        return lowest...highest
    }()

    static let cpuRange: ClosedRange<Int> = {
        let lowest = max(1, VZVirtualMachineConfiguration.minimumAllowedCPUCount)
        let highest = max(lowest, min(VZVirtualMachineConfiguration.maximumAllowedCPUCount, coreCount))
        return lowest...highest
    }()
}

/// User-editable settings, persisted as JSON beside the VM bundle so they can be
/// read and edited without the app running.
struct Settings: Codable, Equatable {
    var memoryGB: Int
    var cpuCount: Int
    var sharedFolderPath: String
    var enableRosetta: Bool
    var startFullscreen: Bool
    var clipboardSyncEnabled: Bool
    var captureSystemKeys: Bool

    /// 16 GB and 8 cores on a 24 GB / 10 core machine: this app exists to be the
    /// thing you are using, not a background window, so the guest gets the bulk
    /// of the machine and macOS keeps only its working set.
    static let defaults = Settings(
        memoryGB: 16,
        cpuCount: 8,
        sharedFolderPath: FileManager.default.homeDirectoryForCurrentUser.path,
        enableRosetta: true,
        startFullscreen: true,
        clipboardSyncEnabled: true,
        captureSystemKeys: true
    )

    var memoryBytes: UInt64 { UInt64(memoryGB) * 1024 * 1024 * 1024 }

    var sharedFolderURL: URL {
        URL(fileURLWithPath: (sharedFolderPath as NSString).expandingTildeInPath)
    }

    func clamped() -> Settings {
        var copy = self
        copy.memoryGB = min(max(memoryGB, HostLimits.memoryRangeGB.lowerBound),
                            HostLimits.memoryRangeGB.upperBound)
        copy.cpuCount = min(max(cpuCount, HostLimits.cpuRange.lowerBound),
                            HostLimits.cpuRange.upperBound)
        return copy
    }
}

extension Settings {
    /// Every key is optional on the way in, so a file written by an older build
    /// or edited by hand loads with the missing keys defaulted instead of being
    /// rejected wholesale and silently replaced.
    ///
    /// Declared in an extension so the memberwise initialiser survives.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = Settings.defaults
        self.init(
            memoryGB: try container.decodeIfPresent(Int.self, forKey: .memoryGB) ?? fallback.memoryGB,
            cpuCount: try container.decodeIfPresent(Int.self, forKey: .cpuCount) ?? fallback.cpuCount,
            sharedFolderPath: try container.decodeIfPresent(String.self, forKey: .sharedFolderPath) ?? fallback.sharedFolderPath,
            enableRosetta: try container.decodeIfPresent(Bool.self, forKey: .enableRosetta) ?? fallback.enableRosetta,
            startFullscreen: try container.decodeIfPresent(Bool.self, forKey: .startFullscreen) ?? fallback.startFullscreen,
            clipboardSyncEnabled: try container.decodeIfPresent(Bool.self, forKey: .clipboardSyncEnabled) ?? fallback.clipboardSyncEnabled,
            captureSystemKeys: try container.decodeIfPresent(Bool.self, forKey: .captureSystemKeys) ?? fallback.captureSystemKeys
        )
    }
}

/// What happened to a settings edit, so the caller can say so rather than
/// leaving the user to discover it at the next launch.
struct SettingsOutcome {
    /// The values actually in force, which may be clamped versions of what was asked.
    var applied: Settings

    /// Memory or CPU no longer match the machine that is running, so a saved
    /// state can no longer be restored and the next start has to be a cold boot.
    var coldBootRequired: Bool

    /// Something changed that only the next start can pick up.
    var needsRestart: Bool
}

/// Loads, clamps and persists `Settings`.
///
/// `requested` is kept alongside `settings` so the UI can show *both* — a value
/// that was quietly reduced because the host could not honour it is worth
/// saying out loud.
final class SettingsStore {
    static let shared = SettingsStore()

    private(set) var settings: Settings
    private(set) var requested: Settings

    private init() {
        let stored = Self.read()
        requested = stored ?? .defaults
        settings = requested.clamped()

        if settings.memoryGB != requested.memoryGB {
            Log.warn("settings.json asks for \(requested.memoryGB) GB; this Mac allows at most \(HostLimits.memoryRangeGB.upperBound) GB. Using \(settings.memoryGB) GB.")
        }
        if settings.cpuCount != requested.cpuCount {
            Log.warn("settings.json asks for \(requested.cpuCount) processors; this Mac allows at most \(HostLimits.cpuRange.upperBound). Using \(settings.cpuCount).")
        }
        // Write a file on first run so there is something to look at and edit.
        if stored == nil { write() }
    }

    /// Clamps, persists, and hands back the values that are actually in force.
    @discardableResult
    func apply(_ incoming: Settings) -> Settings {
        requested = incoming
        let clamped = incoming.clamped()
        guard clamped != settings else { return settings }
        settings = clamped
        write()
        return settings
    }

    private static func read() -> Settings? {
        guard let data = try? Data(contentsOf: Paths.settings) else { return nil }
        guard let decoded = try? JSONDecoder().decode(Settings.self, from: data) else {
            Log.warn("Could not parse \(Paths.settings.path). Using defaults.")
            return nil
        }
        return decoded
    }

    private func write() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(settings).write(to: Paths.settings, options: .atomic)
        } catch {
            Log.error("Could not write \(Paths.settings.path): \(error.localizedDescription)")
        }
    }
}
