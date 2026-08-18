import AppKit
import Virtualization

/// Owns the virtual machine and the single fullscreen window it lives in.
/// Everything here runs on the main queue, which is the queue `VZVirtualMachine`
/// is created on and therefore the only one allowed to touch it.
final class VMSession: NSObject, VZVirtualMachineDelegate, NSWindowDelegate {
    private let machine: VZVirtualMachine
    private let canSuspend: Bool
    private let window: NSWindow
    private let view: VZVirtualMachineView
    private let startFullscreen: Bool

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

    init(configuration: VZVirtualMachineConfiguration, fullscreen: Bool) {
        machine = VZVirtualMachine(configuration: configuration)
        startFullscreen = fullscreen

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
        view.capturesSystemKeys = true
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
    }

    // MARK: - Lifecycle

    func start() {
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        NSApp.activate(ignoringOtherApps: true)

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
                }
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
        do {
            try await machine.restoreMachineStateFrom(url: state)
            try? FileManager.default.removeItem(at: state)
            try await machine.resume()
            Log.info("Resumed from saved state.")
        } catch {
            Log.warn("Saved state could not be restored (\(error.localizedDescription)). Cold booting.")
            try? FileManager.default.removeItem(at: state)
            try await machine.start()
        }
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

        guard canSuspend, machine.state == .running else {
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
