import AppKit
import Foundation
import Virtualization

// MARK: - Options

struct Options {
    var isoPath: String?
    var sharePath: String?
    var rosetta = true
    var fullscreen = true
    var attachISO: Bool?
}

func printUsage() {
    print("""
    linuxonmac — run Debian arm64 on Apple Virtualization.framework

    USAGE
      linuxonmac [options]

    OPTIONS
      --iso <path>     Installer ISO to attach. Defaults to the newest
                       *-arm64-netinst.iso in ~/Downloads until the guest has
                       been installed once.
      --no-iso         Boot from the disk only, never attach an installer.
      --share <path>   Host directory exposed to the guest over virtiofs.
                       Defaults to your home directory. Mount tag: "home".
      --no-rosetta     Skip the Rosetta share (arm64-only guest).
      --windowed       Start in a window instead of fullscreen on its own Space.
      --reset          Delete the VM bundle and start over. Destroys the guest.
      -h, --help       This text.
    """)
}

func parseOptions() -> Options {
    var options = Options()
    var arguments = Array(CommandLine.arguments.dropFirst()).makeIterator()

    while let argument = arguments.next() {
        switch argument {
        case "--iso":
            guard let value = arguments.next() else { die("--iso needs a path") }
            options.isoPath = value
            options.attachISO = true
        case "--no-iso":
            options.attachISO = false
        case "--share":
            guard let value = arguments.next() else { die("--share needs a path") }
            options.sharePath = value
        case "--no-rosetta":
            options.rosetta = false
        case "--windowed":
            options.fullscreen = false
        case "--reset":
            resetBundle()
        case "-h", "--help":
            printUsage()
            exit(0)
        default:
            die("unknown option: \(argument)")
        }
    }
    return options
}

func die(_ message: String) -> Never {
    Log.error(message)
    exit(2)
}

func resetBundle() {
    Log.warn("Deleting \(Paths.bundle.path)")
    try? FileManager.default.removeItem(at: Paths.bundle)
    _ = Paths.bundle  // recreate the directory
}

// MARK: - ISO discovery

/// Attach an installer only while there is something to install. Once the guest
/// has powered off cleanly at least once, booting keeps hitting the disk instead.
func resolveISO(_ options: Options) -> URL? {
    if options.attachISO == false { return nil }
    if let explicit = options.isoPath {
        return URL(fileURLWithPath: (explicit as NSString).expandingTildeInPath)
    }
    if FileManager.default.fileExists(atPath: Paths.installed.path) { return nil }

    let downloads = FileManager.default
        .urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    let candidates = (try? FileManager.default.contentsOfDirectory(
        at: downloads,
        includingPropertiesForKeys: [.contentModificationDateKey]
    )) ?? []

    let isos = candidates
        .filter { $0.lastPathComponent.hasSuffix(".iso") && $0.lastPathComponent.contains("arm64") }
        .sorted { lhs, rhs in
            let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return l > r
        }

    if let newest = isos.first {
        Log.info("Attaching installer: \(newest.lastPathComponent)")
        return newest
    }
    return nil
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let options: Options
    private var session: VMSession?

    init(options: Options) {
        self.options = options
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let share = options.sharePath.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? FileManager.default.homeDirectoryForCurrentUser

        let builder = VMBuilder(
            isoURL: resolveISO(options),
            shareURL: share,
            enableRosetta: options.rosetta
        )

        do {
            let configuration = try builder.makeConfiguration()
            let session = VMSession(configuration: configuration, fullscreen: options.fullscreen)
            self.session = session
            session.start()
        } catch {
            Log.error(error.localizedDescription)
            let alert = NSAlert()
            alert.messageText = "linuxonmac could not build the virtual machine"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .critical
            alert.runModal()
            exit(1)
        }
    }

    /// Closing the window suspends the guest to disk rather than killing it,
    /// so the next launch resumes instead of booting.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let session else { return .terminateNow }
        Task { @MainActor in await session.suspendAndQuit() }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

setvbuf(stdout, nil, _IOLBF, 0)

let options = parseOptions()
Log.info("Starting. Log file: \(Log.fileURL.path)")
let app = NSApplication.shared
let delegate = AppDelegate(options: options)
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
