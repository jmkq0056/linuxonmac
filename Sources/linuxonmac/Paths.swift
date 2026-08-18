import Foundation

/// Everything the VM owns lives in one bundle directory so it can be moved,
/// backed up, or deleted as a unit.
enum Paths {
    static let bundle: URL = {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("linuxonmac", isDirectory: true)
            .appendingPathComponent("Debian.vm", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    static var disk: URL { bundle.appendingPathComponent("disk.img") }
    static var nvram: URL { bundle.appendingPathComponent("nvram") }
    static var machineIdentifier: URL { bundle.appendingPathComponent("machine-identifier") }
    static var savedState: URL { bundle.appendingPathComponent("state.vzvmsave") }
    static var installed: URL { bundle.appendingPathComponent("installed") }
}

enum Tunables {
    /// Sparse — it only consumes what the guest actually writes.
    static let diskSizeBytes: UInt64 = 96 * 1024 * 1024 * 1024
    static let memoryBytes: UInt64 = 10 * 1024 * 1024 * 1024
    static let cpuCount = 6
    static let homeShareTag = "home"
    static let rosettaShareTag = "rosetta"
}
