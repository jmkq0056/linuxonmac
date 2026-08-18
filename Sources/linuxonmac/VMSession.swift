import AppKit
import Virtualization

/// Owns the virtual machine and the single fullscreen window it lives in.
/// Everything here runs on the main queue, which is the queue `VZVirtualMachine`
/// is created on and therefore the only one allowed to touch it.
final class VMSession: NSObject, VZVirtualMachineDelegate, NSWindowDelegate, VMActions {
    private let machine: VZVirtualMachine
    private let canSuspend: Bool
    private let window: NSWindow
    private let view: VZVirtualMachineView
    private let startFullscreen: Bool
    let sharedFolderURL: URL

    /// The settings the configuration this session is running was built from.
    /// A saved state is only restorable into these exact numbers.
    let launchSettings: Settings

    private var clipboard: ClipboardBridge?
    private var menus: MenuController?
    private var splash: SplashWindow?
    private var settingsWindow: SettingsWindowController?

    /// Set when memory or CPU are edited away from `launchSettings`. Suspending
    /// would then write a state file that no future launch could restore, so the
    /// guest is shut down cleanly on quit instead.
    private var resumeBlocked = false

    /// Distinguishes the two launch paths for the splash, which have genuinely
    /// different things to wait on.
    private var didResume = false

    /// Set while a restart is in flight so `guestDidStop` boots again instead of
    /// terminating the app.
    private var isRestarting = false

    /// True once we have handed the guest a shutdown or a save, so the
    /// stop callbacks know the exit was intentional.
    private var isWindingDown = false

    /// `replyToApplicationShouldTerminate:` must be called exactly once, and
    /// only in response to a pending `.terminateLater`. Replying twice, or
    /// replying with nothing pending, leaves the app wedged and never exiting.
    private var hasRepliedToTermination = false

    /// Nothing left to save once the guest has stopped, so termination can
    /// complete synchronously instead of going through `.terminateLater`.
    var canTerminateImmediately: Bool {
        switch machine.state {
        case .stopped, .error: return true
        default: return false
        }
    }

    init(configuration: VZVirtualMachineConfiguration, settings: Settings) {
        machine = VZVirtualMachine(configuration: configuration)
        launchSettings = settings
        startFullscreen = settings.startFullscreen
        sharedFolderURL = settings.sharedFolderURL

        // Not every device combination can be frozen to disk. Ask once, up front,
        // so closing the window never blocks on a save that was always going to fail.
        do {
            try configuration.validateSaveRestoreSupport()
            canSuspend = true
        } catch {
            Log.warn("Suspend to disk unavailable: \(error.localizedDescription)")
            canSuspend = false
        }

        view = VZVirtualMachineView()
        view.virtualMachine = machine
        view.capturesSystemKeys = settings.captureSystemKeys
        view.automaticallyReconfiguresDisplay = true

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 832),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()

        window.title = "Debian"
        window.contentView = view
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("LinuxOnMacWindow")
        // .fullScreenPrimary is what makes macOS give the window its own Space
        // rather than sharing the desktop it was launched from.
        window.collectionBehavior = [.fullScreenPrimary, .managed]
        machine.delegate = self
        menus = MenuController(actions: self)
    }

    // MARK: - Lifecycle

    func start() {
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        NSApp.activate(ignoringOtherApps: true)

        let splash = SplashWindow(
            subtitle: "Debian · \(launchSettings.memoryGB) GB · \(launchSettings.cpuCount) processors"
        )
        self.splash = splash
        splash.show(phase: .startingMachine)

        if startFullscreen {
            // Has to wait until the window is actually on screen, otherwise
            // AppKit silently drops the transition.
            DispatchQueue.main.async { [window] in window.toggleFullScreen(nil) }
        }

        Task { @MainActor in
            do {
                if FileManager.default.fileExists(atPath: Paths.savedState.path) {
                    try await resumeFromDisk()
                } else {
                    try await machine.start()
                    Log.info("Booting.")
                    splash.update(phase: .bootingGuest)
                }
                self.attachClipboardBridge()
            } catch {
                self.fail("Could not start the virtual machine: \(error.localizedDescription)")
            }
        }
    }

    /// Restore is one-shot: the state file is consumed so a crashed restore
    /// can never be replayed into a corrupt guest a second time.
    @MainActor
    private func resumeFromDisk() async throws {
        let state = Paths.savedState
        splash?.update(phase: .resumingState)
        do {
            try await machine.restoreMachineStateFrom(url: state)
            try? FileManager.default.removeItem(at: state)
            try await machine.resume()
            Log.info("Resumed from saved state.")
            // The guest is already up, so the only thing still outstanding is
            // the bridge reconnecting to the agent inside it.
            didResume = true
            splash?.update(phase: .connectingClipboard)
            attachClipboardBridge()
        } catch {
            Log.warn("Saved state could not be restored (\(error.localizedDescription)). Cold booting.")
            try? FileManager.default.removeItem(at: state)
            splash?.update(phase: .bootingGuest)
            try await machine.start()
        }
    }

    /// The socket device only exists on a started machine, so this cannot run
    /// any earlier than the first successful start or restore.
    @MainActor
    private func attachClipboardBridge() {
        guard clipboard == nil,
              let socket = machine.socketDevices.first as? VZVirtioSocketDevice
        else { return }
        let bridge = ClipboardBridge(device: socket)
        bridge.isEnabled = SettingsStore.shared.settings.clipboardSyncEnabled
        bridge.onStateChange = { [weak self] connected in
            Log.info("Clipboard bridge \(connected ? "connected" : "disconnected").")
            // The agent only starts with the graphical session, so this is the
            // first moment the guest is genuinely usable.
            if connected { self?.splash?.dismiss() }
        }
        clipboard = bridge
        bridge.start()

        // A guest without the agent installed never connects, and the splash
        // must not outlive the boot it is describing. A resume has nothing left
        // to wait for, so it gives up far sooner than a cold boot does.
        splash?.armFallbackDismiss(after: didResume ? 20 : 75)
    }

    // MARK: - VMActions

    var isPaused: Bool { machine.state == .paused }
    var capturesSystemKeys: Bool { view.capturesSystemKeys }
    /// Read from the store rather than the bridge so the menus show the right
    /// state before the bridge exists — which is most of the boot.
    var clipboardSyncEnabled: Bool { SettingsStore.shared.settings.clipboardSyncEnabled }
    var clipboardConnected: Bool { clipboard?.isConnected ?? false }

    func suspendAndQuitFromMenu() { NSApp.terminate(nil) }

    func shutDownGuest() {
        guard machine.canRequestStop else { return }
        try? machine.requestStop()
    }

    func forceStopGuest() {
        Task { @MainActor in try? await machine.stop() }
    }

    func restartGuest() {
        guard machine.canRequestStop else { return }
        isRestarting = true
        try? machine.requestStop()
    }

    func togglePause() {
        Task { @MainActor in
            do {
                if machine.state == .paused {
                    try await machine.resume()
                } else if machine.state == .running {
                    try await machine.pause()
                }
            } catch {
                Log.error("Pause/resume failed: \(error.localizedDescription)")
            }
        }
    }

    func toggleFullScreen() { window.toggleFullScreen(nil) }

    /// The menu toggles go through the settings store rather than poking the
    /// view directly, so a switch flipped from the menu bar is still set the
    /// next time the app launches.
    func toggleCaptureSystemKeys() {
        var next = SettingsStore.shared.settings
        next.captureSystemKeys.toggle()
        _ = applySettings(next)
    }

    func toggleClipboardSync() {
        var next = SettingsStore.shared.settings
        next.clipboardSyncEnabled.toggle()
        let applied = applySettings(next).applied
        Log.info("Clipboard sync \(applied.clipboardSyncEnabled ? "on" : "off").")
    }

    func openSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(actions: self)
        }
        settingsWindow?.presentWindow()
    }

    /// Memory and CPU count are part of the machine configuration, and
    /// `restoreMachineStateFrom(url:)` fails with a bare "invalid argument"
    /// whenever the configuration it is handed differs at all from the one the
    /// state was saved from — the same failure the pinned MAC and scanout exist
    /// to avoid.
    ///
    /// So a sizing change has to invalidate resume in *both* directions: any
    /// state already on disk is deleted, and this session stops suspending on
    /// quit, because the file it would write could never be restored either.
    /// Setting the values back to what is running lifts both again.
    func applySettings(_ requested: Settings) -> SettingsOutcome {
        let applied = SettingsStore.shared.apply(requested)

        view.capturesSystemKeys = applied.captureSystemKeys
        clipboard?.isEnabled = applied.clipboardSyncEnabled

        let sizingChanged = applied.memoryGB != launchSettings.memoryGB
            || applied.cpuCount != launchSettings.cpuCount

        if sizingChanged {
            if FileManager.default.fileExists(atPath: Paths.savedState.path) {
                try? FileManager.default.removeItem(at: Paths.savedState)
                Log.warn("Deleted \(Paths.savedState.lastPathComponent): it was saved from a different configuration.")
            }
            if !resumeBlocked {
                Log.warn("Resume disabled: \(applied.memoryGB) GB / \(applied.cpuCount) processors requested, \(launchSettings.memoryGB) GB / \(launchSettings.cpuCount) running. The next start will be a cold boot.")
            }
        } else if resumeBlocked {
            Log.info("Memory and processors match the running machine again. Resume is back.")
        }
        resumeBlocked = sizingChanged

        let needsRestart = sizingChanged
            || applied.sharedFolderPath != launchSettings.sharedFolderPath
            || applied.enableRosetta != launchSettings.enableRosetta

        return SettingsOutcome(
            applied: applied,
            coldBootRequired: sizingChanged,
            needsRestart: needsRestart
        )
    }

    func pushClipboardToGuest() { clipboard?.pushNow() }

    func openSharedFolder() { NSWorkspace.shared.open(sharedFolderURL) }

    func revealVMBundle() {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: Paths.bundle.path)
    }

    private var sshCommand: String {
        let host = GuestNetwork.guestIP ?? "192.168.64.7"
        return "ssh -i ~/.ssh/linuxonmac \(NSUserName())@\(host)"
    }

    func copySSHCommand() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(sshCommand, forType: .string)
        Log.info("Copied: \(sshCommand)")
    }

    func openTerminalSession() {
        let script = "tell application \"Terminal\" to do script \"\(sshCommand)\"\ntell application \"Terminal\" to activate"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
    }

    /// Suspend to disk so the next launch is instant. Falls back to a graceful
    /// ACPI shutdown when the configuration or state does not permit saving.
    @MainActor
    func suspendAndQuit() async {
        guard !isWindingDown else {
            finishTermination()
            return
        }
        isWindingDown = true

        // A save that never returns must not strand the app in .terminateLater.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, !self.hasRepliedToTermination else { return }
            Log.warn("Suspend did not finish in 30s. Exiting anyway.")
            self.finishTermination()
        }

        if resumeBlocked {
            Log.warn("Memory or processors were changed this session. Saving state would produce a file no future launch could restore, so the guest is being shut down instead.")
        }

        guard canSuspend, !resumeBlocked, machine.state == .running else {
            await requestGuestShutdown()
            return
        }

        do {
            try await machine.pause()
            try await machine.saveMachineStateTo(url: Paths.savedState)
            Log.info("Suspended to disk.")
            finishTermination()
        } catch {
            Log.warn("Suspend failed (\(error.localizedDescription)). Asking the guest to shut down.")
            try? FileManager.default.removeItem(at: Paths.savedState)
            if machine.state == .paused { try? await machine.resume() }
            await requestGuestShutdown()
        }
    }

    @MainActor
    private func requestGuestShutdown() async {
        guard machine.canRequestStop else {
            finishTermination()
            return
        }
        do {
            try machine.requestStop()
            Log.info("Sent shutdown request to the guest.")
            // guestDidStop(_:) replies to the termination request.
        } catch {
            Log.error("Shutdown request failed: \(error.localizedDescription)")
            finishTermination()
        }
    }

    private func finishTermination() {
        guard !hasRepliedToTermination else { return }
        hasRepliedToTermination = true
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    private func fail(_ message: String) {
        splash?.dismiss()
        Log.error(message)
        let alert = NSAlert()
        alert.messageText = "linuxonmac could not start"
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.runModal()
        NSApp.terminate(nil)
    }

    // MARK: - VZVirtualMachineDelegate

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        Log.info("Guest powered off.")
        markInstalledIfNeeded()

        if isRestarting {
            isRestarting = false
            clipboard?.stop()
            clipboard = nil
            Task { @MainActor in
                do {
                    try await machine.start()
                    Log.info("Restarted.")
                    attachClipboardBridge()
                } catch {
                    Log.error("Restart failed: \(error.localizedDescription)")
                    NSApp.terminate(nil)
                }
            }
            return
        }

        isWindingDown = true
        NSApp.terminate(nil)
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        Log.error("Guest stopped unexpectedly: \(error.localizedDescription)")
        isWindingDown = true
        NSApp.terminate(nil)
    }

    func virtualMachine(
        _ virtualMachine: VZVirtualMachine,
        networkDevice: VZNetworkDevice,
        attachmentWasDisconnectedWithError error: Error
    ) {
        Log.warn("Network detached: \(error.localizedDescription)")
    }

    /// The first clean power-off after an install is the signal that the ISO
    /// is no longer needed on subsequent launches.
    private func markInstalledIfNeeded() {
        guard !FileManager.default.fileExists(atPath: Paths.installed.path) else { return }
        FileManager.default.createFile(atPath: Paths.installed.path, contents: Data())
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApp.terminate(nil)
        return false
    }
}
