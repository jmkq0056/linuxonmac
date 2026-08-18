import AppKit

/// What the menus can ask of the running session.
protocol VMActions: AnyObject {
    func suspendAndQuitFromMenu()
    func shutDownGuest()
    func forceStopGuest()
    func restartGuest()
    func togglePause()
    func toggleFullScreen()
    func toggleCaptureSystemKeys()
    func toggleClipboardSync()
    func pushClipboardToGuest()
    func openSharedFolder()
    func revealVMBundle()
    func copySSHCommand()
    func openTerminalSession()

    var isPaused: Bool { get }
    var capturesSystemKeys: Bool { get }
    var clipboardSyncEnabled: Bool { get }
    var clipboardConnected: Bool { get }
    var sharedFolderURL: URL { get }
}

/// Builds the menu bar and the status item.
///
/// Both exist because `capturesSystemKeys` hands most key combinations to the
/// guest, and because the window spends its life fullscreen on another Space —
/// a status item is reachable in both situations, a menu bar is not.
final class MenuController: NSObject, NSMenuDelegate {
    private weak var actions: VMActions?
    private var statusItem: NSStatusItem?

    init(actions: VMActions) {
        self.actions = actions
        super.init()
        installMainMenu()
        installStatusItem()
    }

    // MARK: - Menu bar

    private func installMainMenu() {
        let main = NSMenu()

        main.addItem(appMenuItem())
        main.addItem(machineMenuItem())
        main.addItem(clipboardMenuItem())
        main.addItem(viewMenuItem())
        main.addItem(foldersMenuItem())
        main.addItem(helpMenuItem())

        NSApp.mainMenu = main
    }

    private func submenu(_ title: String, _ build: (NSMenu) -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        menu.delegate = self
        build(menu)
        item.submenu = menu
        return item
    }

    private func add(
        _ menu: NSMenu,
        _ title: String,
        _ selector: Selector?,
        _ key: String = "",
        _ modifiers: NSEvent.ModifierFlags = [.command]
    ) {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = selector == nil ? nil : self
        menu.addItem(item)
    }

    private func appMenuItem() -> NSMenuItem {
        submenu("linuxonmac") { menu in
            add(menu, "About linuxonmac", #selector(about))
            menu.addItem(.separator())
            add(menu, "Hide linuxonmac", #selector(NSApplication.hide(_:)), "h")
            let hideOthers = NSMenuItem(
                title: "Hide Others",
                action: #selector(NSApplication.hideOtherApplications(_:)),
                keyEquivalent: "h"
            )
            hideOthers.keyEquivalentModifierMask = [.command, .option]
            menu.addItem(hideOthers)
            menu.addItem(.separator())
            // Quit suspends rather than kills — the point of the whole thing.
            add(menu, "Suspend & Quit", #selector(suspendAndQuit), "q")
        }
    }

    private func machineMenuItem() -> NSMenuItem {
        submenu("Machine") { menu in
            add(menu, "Pause", #selector(togglePause), "p", [.command, .control])
            add(menu, "Restart Guest", #selector(restartGuest), "r", [.command, .control])
            menu.addItem(.separator())
            add(menu, "Shut Down Guest", #selector(shutDown), "q", [.command, .control])
            add(menu, "Force Stop", #selector(forceStop))
            menu.addItem(.separator())
            add(menu, "Guest IP", nil)
            add(menu, "Copy SSH Command", #selector(copySSH), "s", [.command, .control])
            add(menu, "Open SSH in Terminal", #selector(openTerminal), "t", [.command, .control])
        }
    }

    private func clipboardMenuItem() -> NSMenuItem {
        submenu("Clipboard") { menu in
            add(menu, "Bridge Status", nil)
            menu.addItem(.separator())
            add(menu, "Sync with macOS", #selector(toggleSync), "k", [.command, .control])
            add(menu, "Send Clipboard to Linux", #selector(pushClipboard), "c", [.command, .control])
        }
    }

    private func viewMenuItem() -> NSMenuItem {
        submenu("View") { menu in
            add(menu, "Enter Full Screen", #selector(toggleFullScreen), "f", [.command, .control])
            menu.addItem(.separator())
            add(menu, "Capture System Keys", #selector(toggleCaptureKeys))
        }
    }

    private func foldersMenuItem() -> NSMenuItem {
        submenu("Folders") { menu in
            add(menu, "Open Shared Folder", #selector(openShared), "o", [.command, .shift])
            add(menu, "Reveal VM Bundle in Finder", #selector(revealBundle))
        }
    }

    private func helpMenuItem() -> NSMenuItem {
        submenu("Help") { menu in
            add(menu, "Guest Setup Guide", #selector(openGuide))
            add(menu, "Project on GitHub", #selector(openRepo))
        }
    }

    // MARK: - Status item

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "desktopcomputer",
            accessibilityDescription: "linuxonmac"
        )
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        rebuildStatusMenu(menu)
    }

    private func rebuildStatusMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let actions else { return }

        let state = NSMenuItem(
            title: actions.isPaused ? "Paused" : "Running",
            action: nil, keyEquivalent: ""
        )
        state.isEnabled = false
        menu.addItem(state)

        let clipboard = NSMenuItem(
            title: actions.clipboardConnected
                ? (actions.clipboardSyncEnabled ? "Clipboard: synced" : "Clipboard: paused")
                : "Clipboard: connecting…",
            action: nil, keyEquivalent: ""
        )
        clipboard.isEnabled = false
        menu.addItem(clipboard)

        if let ip = GuestNetwork.guestIP {
            let address = NSMenuItem(title: "Guest: \(ip)", action: nil, keyEquivalent: "")
            address.isEnabled = false
            menu.addItem(address)
        }

        menu.addItem(.separator())
        add(menu, actions.isPaused ? "Resume" : "Pause", #selector(togglePause))
        add(menu, "Enter Full Screen", #selector(toggleFullScreen))
        add(menu, "Open SSH in Terminal", #selector(openTerminal))
        add(menu, "Open Shared Folder", #selector(openShared))
        menu.addItem(.separator())
        add(menu, "Sync Clipboard", #selector(toggleSync))
        add(menu, "Send Clipboard to Linux", #selector(pushClipboard))
        menu.addItem(.separator())
        add(menu, "Shut Down Guest", #selector(shutDown))
        add(menu, "Suspend & Quit", #selector(suspendAndQuit))
    }

    // MARK: - Live state

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let actions else { return }

        if menu === statusItem?.menu {
            rebuildStatusMenu(menu)
            return
        }

        for item in menu.items {
            switch item.title {
            case "Pause", "Resume":
                item.title = actions.isPaused ? "Resume" : "Pause"
            case "Capture System Keys":
                item.state = actions.capturesSystemKeys ? .on : .off
            case "Sync with macOS":
                item.state = actions.clipboardSyncEnabled ? .on : .off
            case "Bridge Status":
                item.title = actions.clipboardConnected ? "Connected over vsock" : "Connecting…"
                item.isEnabled = false
            case "Guest IP":
                item.title = GuestNetwork.guestIP.map { "Guest IP: \($0)" } ?? "Guest IP: unknown"
                item.isEnabled = false
            case "Enter Full Screen", "Exit Full Screen":
                let isFullScreen = NSApp.keyWindow?.styleMask.contains(.fullScreen) ?? false
                item.title = isFullScreen ? "Exit Full Screen" : "Enter Full Screen"
            default:
                break
            }
        }
    }

    // MARK: - Actions

    @objc private func suspendAndQuit() { actions?.suspendAndQuitFromMenu() }
    @objc private func shutDown() { actions?.shutDownGuest() }
    @objc private func forceStop() { actions?.forceStopGuest() }
    @objc private func restartGuest() { actions?.restartGuest() }
    @objc private func togglePause() { actions?.togglePause() }
    @objc private func toggleFullScreen() { actions?.toggleFullScreen() }
    @objc private func toggleCaptureKeys() { actions?.toggleCaptureSystemKeys() }
    @objc private func toggleSync() { actions?.toggleClipboardSync() }
    @objc private func pushClipboard() { actions?.pushClipboardToGuest() }
    @objc private func openShared() { actions?.openSharedFolder() }
    @objc private func revealBundle() { actions?.revealVMBundle() }
    @objc private func copySSH() { actions?.copySSHCommand() }
    @objc private func openTerminal() { actions?.openTerminalSession() }

    @objc private func openGuide() {
        NSWorkspace.shared.open(URL(string: "https://github.com/jmkq0056/linuxonmac/blob/main/docs/GUEST-SETUP.md")!)
    }

    @objc private func openRepo() {
        NSWorkspace.shared.open(URL(string: "https://github.com/jmkq0056/linuxonmac")!)
    }

    @objc private func about() {
        let alert = NSAlert()
        alert.messageText = "linuxonmac"
        alert.informativeText = """
        Debian arm64 on Apple Virtualization.framework.

        Guest: \(GuestNetwork.guestIP ?? "starting…")
        Clipboard: \(actions?.clipboardConnected == true ? "bridged over vsock" : "connecting")
        Shared folder: \(actions?.sharedFolderURL.path ?? "—")
        """
        alert.runModal()
    }
}
