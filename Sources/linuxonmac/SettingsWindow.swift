import AppKit

/// The Settings window, built in code because the app ships no nib and no
/// storyboard.
///
/// Edits commit on a short debounce instead of behind an OK button: dragging the
/// memory slider from 8 to 18 would otherwise fire eleven configuration changes,
/// each one invalidating resume, before the user let go of the mouse.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private weak var actions: VMActions?

    private let contentWidth: CGFloat = 470

    private let memorySlider = NSSlider()
    private let memoryStepper = NSStepper()
    private let memoryValue = NSTextField(labelWithString: "")
    private let memoryNote = NSTextField(wrappingLabelWithString: "")

    private let cpuSlider = NSSlider()
    private let cpuStepper = NSStepper()
    private let cpuValue = NSTextField(labelWithString: "")
    private let cpuNote = NSTextField(wrappingLabelWithString: "")

    private let diskValue = NSTextField(labelWithString: "")
    private let shareValue = NSTextField(labelWithString: "")

    private let rosettaCheck = NSButton(
        checkboxWithTitle: "Run x86_64 Linux binaries through Rosetta", target: nil, action: nil)
    private let fullscreenCheck = NSButton(
        checkboxWithTitle: "Start fullscreen on its own Space", target: nil, action: nil)
    private let clipboardCheck = NSButton(
        checkboxWithTitle: "Keep the clipboard in sync with macOS", target: nil, action: nil)
    private let captureCheck = NSButton(
        checkboxWithTitle: "Send system keys such as ⌘Tab to the guest", target: nil, action: nil)

    private let restartNote = NSTextField(wrappingLabelWithString: "")
    private let banner = NSStackView()
    private let bannerText = NSTextField(wrappingLabelWithString: "")

    private var sharedFolderPath = Settings.defaults.sharedFolderPath
    private var commitTimer: Timer?
    private var hasWarnedAboutColdBoot = false

    init(actions: VMActions) {
        self.actions = actions
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)

        window.title = "Settings"
        // A window built in code releases itself when closed, which would leave
        // this controller holding a freed window the second time the menu item
        // is used.
        window.isReleasedWhenClosed = false
        window.delegate = self
        // The VM window is usually fullscreen on another Space; without this the
        // Settings window opens somewhere the user cannot see it.
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]

        buildInterface()
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("Settings is never loaded from a nib") }

    func presentWindow() {
        refresh()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Construction

    private func buildInterface() {
        guard let window else { return }

        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.rowSpacing = 8
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading

        configureControls()

        addHeader(grid, "Machine", first: true)
        addRow(grid, "Memory", pairing(memorySlider, memoryStepper, memoryValue))
        addNote(grid, memoryNote)
        addRow(grid, "Processors", pairing(cpuSlider, cpuStepper, cpuValue))
        addNote(grid, cpuNote)
        addRow(grid, "Disk", diskValue)
        addNote(grid, caption(
            "Fixed when the image was created. Growing it would also mean growing the guest's partition table and filesystem, which the host cannot do from here."))

        addHeader(grid, "Sharing")
        addRow(grid, "Shared folder", shareControls())
        addNote(grid, caption("Mounted in the guest over virtiofs with the tag “\(VMConstants.homeShareTag)”."))
        addRow(grid, "Rosetta", rosettaCheck)

        addHeader(grid, "Session")
        addRow(grid, "Window", fullscreenCheck)
        addRow(grid, "Clipboard", clipboardCheck)
        addRow(grid, "Keyboard", captureCheck)

        let column = NSStackView(views: [grid, footer()])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 18
        column.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 20, right: 22)
        column.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            column.topAnchor.constraint(equalTo: content.topAnchor),
            column.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        window.contentView = content
        content.layoutSubtreeIfNeeded()
        window.setContentSize(content.fittingSize)
        window.center()
    }

    private func configureControls() {
        for slider in [memorySlider, cpuSlider] {
            slider.target = self
            slider.action = #selector(sliderMoved(_:))
            slider.isContinuous = true
            slider.allowsTickMarkValuesOnly = true
            slider.widthAnchor.constraint(equalToConstant: 210).isActive = true
        }
        for stepper in [memoryStepper, cpuStepper] {
            stepper.target = self
            stepper.action = #selector(stepperClicked(_:))
            stepper.increment = 1
            stepper.valueWraps = false
        }
        for value in [memoryValue, cpuValue] {
            value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            value.widthAnchor.constraint(equalToConstant: 74).isActive = true
        }
        for check in [rosettaCheck, fullscreenCheck, clipboardCheck, captureCheck] {
            check.target = self
            check.action = #selector(checkboxClicked(_:))
        }
        for note in [memoryNote, cpuNote] {
            note.font = .systemFont(ofSize: 11)
            note.textColor = .secondaryLabelColor
            note.widthAnchor.constraint(equalToConstant: 300).isActive = true
        }
        shareValue.lineBreakMode = .byTruncatingMiddle
        shareValue.widthAnchor.constraint(equalToConstant: 232).isActive = true
    }

    private func pairing(_ slider: NSSlider, _ stepper: NSStepper, _ value: NSTextField) -> NSView {
        let stack = NSStackView(views: [slider, stepper, value])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        return stack
    }

    private func shareControls() -> NSView {
        let choose = NSButton(title: "Choose…", target: self, action: #selector(chooseSharedFolder))
        choose.bezelStyle = .rounded
        let stack = NSStackView(views: [shareValue, choose])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        return stack
    }

    private func footer() -> NSView {
        let separator = NSBox()
        separator.boxType = .separator
        separator.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true

        restartNote.font = .systemFont(ofSize: 11)
        restartNote.textColor = .secondaryLabelColor
        restartNote.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true

        buildBanner()

        let restore = NSButton(title: "Restore Defaults", target: self, action: #selector(restoreDefaults))
        restore.bezelStyle = .rounded
        let reveal = NSButton(title: "Reveal settings.json", target: self, action: #selector(revealSettingsFile))
        reveal.bezelStyle = .rounded

        let buttons = NSStackView(views: [restore, reveal])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        let stack = NSStackView(views: [separator, restartNote, banner, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        return stack
    }

    private func buildBanner() {
        let icon = NSImageView()
        icon.image = NSImage(
            systemSymbolName: "exclamationmark.triangle.fill",
            accessibilityDescription: "Warning"
        )
        icon.contentTintColor = .systemOrange
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true

        bannerText.font = .systemFont(ofSize: 11)
        bannerText.textColor = .labelColor
        bannerText.widthAnchor.constraint(equalToConstant: contentWidth - 26).isActive = true

        banner.orientation = .horizontal
        banner.alignment = .top
        banner.spacing = 8
        banner.addArrangedSubview(icon)
        banner.addArrangedSubview(bannerText)
        banner.isHidden = true
    }

    // MARK: - Grid helpers

    private func addHeader(_ grid: NSGridView, _ title: String, first: Bool = false) {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        let row = grid.addRow(with: [label])
        row.mergeCells(in: NSRange(location: 0, length: 2))
        row.cell(at: 0).xPlacement = .leading
        row.topPadding = first ? 0 : 14
        row.bottomPadding = 2
    }

    private func addRow(_ grid: NSGridView, _ title: String, _ control: NSView) {
        let label = NSTextField(labelWithString: "\(title):")
        label.textColor = .labelColor
        grid.addRow(with: [label, control])
    }

    private func addNote(_ grid: NSGridView, _ note: NSTextField) {
        grid.addRow(with: [NSGridCell.emptyContentView, note])
    }

    private func caption(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: 11)
        field.textColor = .secondaryLabelColor
        field.widthAnchor.constraint(equalToConstant: 300).isActive = true
        return field
    }

    // MARK: - State

    private func refresh() {
        let store = SettingsStore.shared
        let settings = store.settings
        sharedFolderPath = settings.sharedFolderPath

        let memory = HostLimits.memoryRangeGB
        memorySlider.minValue = Double(memory.lowerBound)
        memorySlider.maxValue = Double(memory.upperBound)
        memorySlider.numberOfTickMarks = memory.count
        memorySlider.doubleValue = Double(settings.memoryGB)
        memoryStepper.minValue = Double(memory.lowerBound)
        memoryStepper.maxValue = Double(memory.upperBound)
        memoryStepper.integerValue = settings.memoryGB
        memoryValue.stringValue = "\(settings.memoryGB) GB"

        let cpu = HostLimits.cpuRange
        cpuSlider.minValue = Double(cpu.lowerBound)
        cpuSlider.maxValue = Double(cpu.upperBound)
        cpuSlider.numberOfTickMarks = cpu.count
        cpuSlider.doubleValue = Double(settings.cpuCount)
        cpuStepper.minValue = Double(cpu.lowerBound)
        cpuStepper.maxValue = Double(cpu.upperBound)
        cpuStepper.integerValue = settings.cpuCount
        cpuValue.stringValue = settings.cpuCount == 1 ? "1 core" : "\(settings.cpuCount) cores"

        memoryNote.stringValue = memoryCaption(store)
        memoryNote.textColor = store.requested.memoryGB == settings.memoryGB
            ? .secondaryLabelColor : .systemOrange
        cpuNote.stringValue = cpuCaption(store)
        cpuNote.textColor = store.requested.cpuCount == settings.cpuCount
            ? .secondaryLabelColor : .systemOrange

        let gigabytes = VMConstants.diskSizeBytes / (1024 * 1024 * 1024)
        diskValue.stringValue = "\(gigabytes) GB, sparse"

        let abbreviated = (sharedFolderPath as NSString).abbreviatingWithTildeInPath
        shareValue.stringValue = abbreviated == "~" ? "~ (your home folder)" : abbreviated
        shareValue.toolTip = sharedFolderPath

        rosettaCheck.state = settings.enableRosetta ? .on : .off
        fullscreenCheck.state = settings.startFullscreen ? .on : .off
        clipboardCheck.state = settings.clipboardSyncEnabled ? .on : .off
        captureCheck.state = settings.captureSystemKeys ? .on : .off

        refreshFooter(settings)
        resizeToFit()
    }

    private func memoryCaption(_ store: SettingsStore) -> String {
        let ceiling = HostLimits.memoryRangeGB.upperBound
        var text = "This Mac has \(HostLimits.physicalMemoryGB) GB. "
            + "\(HostLimits.reservedForHostGB) GB stays with macOS, so \(ceiling) GB is the ceiling."
        if store.requested.memoryGB != store.settings.memoryGB {
            text = "Asked for \(store.requested.memoryGB) GB — clamped to \(store.settings.memoryGB) GB. " + text
        }
        return text
    }

    private func cpuCaption(_ store: SettingsStore) -> String {
        let usable = HostLimits.cpuRange.upperBound
        var text = usable < HostLimits.coreCount
            ? "\(HostLimits.coreCount) cores on this Mac, \(usable) usable. "
            : "\(HostLimits.coreCount) cores on this Mac. "
        text += "Oversubscribing makes the guest slower, not faster."
        if store.requested.cpuCount != store.settings.cpuCount {
            text = "Asked for \(store.requested.cpuCount) — clamped to \(store.settings.cpuCount). " + text
        }
        return text
    }

    private func refreshFooter(_ settings: Settings) {
        guard let launch = actions?.launchSettings else { return }

        var pending: [String] = []
        if settings.memoryGB != launch.memoryGB { pending.append("memory") }
        if settings.cpuCount != launch.cpuCount { pending.append("processors") }
        if settings.sharedFolderPath != launch.sharedFolderPath { pending.append("shared folder") }
        if settings.enableRosetta != launch.enableRosetta { pending.append("Rosetta") }
        if settings.startFullscreen != launch.startFullscreen { pending.append("fullscreen at start") }

        var text = "Memory, processors, the shared folder and Rosetta are part of the machine "
            + "configuration and take effect at the next start. The clipboard and keyboard "
            + "switches apply immediately."
        if !pending.isEmpty {
            text += " Waiting for the next start: \(pending.joined(separator: ", "))."
        }
        restartNote.stringValue = text

        let sizingChanged = settings.memoryGB != launch.memoryGB || settings.cpuCount != launch.cpuCount
        banner.isHidden = !sizingChanged
        if sizingChanged {
            bannerText.stringValue = """
            The running machine has \(launch.memoryGB) GB and \(launch.cpuCount) processors. A saved \
            state can only be restored into the exact configuration it was saved from, so the saved \
            state has been deleted and this session will shut the guest down instead of suspending \
            it — the next start will be a cold boot, not a resume. Set memory and processors back to \
            match to get instant resume back.
            """
        }
    }

    private func resizeToFit() {
        guard let window, let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let target = content.fittingSize
        guard abs(target.height - content.frame.height) > 0.5 else { return }
        let previous = window.frame
        window.setContentSize(target)
        var frame = window.frame
        frame.origin.x = previous.origin.x
        // Keep the title bar still; growing from the bottom left would walk the
        // window up the screen every time the warning appears.
        frame.origin.y = previous.maxY - frame.height
        window.setFrame(frame, display: true, animate: false)
    }

    // MARK: - Editing

    @objc private func sliderMoved(_ sender: NSSlider) {
        if sender === memorySlider {
            memoryStepper.integerValue = Int(sender.doubleValue.rounded())
            memoryValue.stringValue = "\(memoryStepper.integerValue) GB"
        } else {
            cpuStepper.integerValue = Int(sender.doubleValue.rounded())
            cpuValue.stringValue = cpuStepper.integerValue == 1 ? "1 core" : "\(cpuStepper.integerValue) cores"
        }
        scheduleCommit()
    }

    @objc private func stepperClicked(_ sender: NSStepper) {
        if sender === memoryStepper {
            memorySlider.doubleValue = Double(sender.integerValue)
            memoryValue.stringValue = "\(sender.integerValue) GB"
        } else {
            cpuSlider.doubleValue = Double(sender.integerValue)
            cpuValue.stringValue = sender.integerValue == 1 ? "1 core" : "\(sender.integerValue) cores"
        }
        scheduleCommit()
    }

    @objc private func checkboxClicked(_ sender: NSButton) { commit() }

    private func scheduleCommit() {
        commitTimer?.invalidate()
        commitTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
            self?.commit()
        }
    }

    private func commit() {
        commitTimer?.invalidate()
        commitTimer = nil
        guard let actions else { return }

        var next = SettingsStore.shared.settings
        next.memoryGB = memoryStepper.integerValue
        next.cpuCount = cpuStepper.integerValue
        next.sharedFolderPath = sharedFolderPath
        next.enableRosetta = rosettaCheck.state == .on
        next.startFullscreen = fullscreenCheck.state == .on
        next.clipboardSyncEnabled = clipboardCheck.state == .on
        next.captureSystemKeys = captureCheck.state == .on

        guard next != SettingsStore.shared.settings else {
            refresh()
            return
        }

        let outcome = actions.applySettings(next)
        refresh()

        if outcome.coldBootRequired && !hasWarnedAboutColdBoot {
            hasWarnedAboutColdBoot = true
            warnAboutColdBoot(outcome)
        }
    }

    /// Said once, plainly, as a sheet — the banner in the window keeps saying it
    /// for as long as the mismatch stands.
    private func warnAboutColdBoot(_ outcome: SettingsOutcome) {
        guard let window, let launch = actions?.launchSettings else { return }
        let alert = NSAlert()
        alert.messageText = "The next start will be a cold boot"
        alert.informativeText = """
        Memory and processor count are part of the virtual machine configuration, and a saved state \
        can only be restored into the configuration it was saved from — restoring into a different \
        one fails outright.

        The saved state has been deleted, and quitting will now shut the guest down cleanly instead \
        of suspending it. Debian will boot from scratch next time with \(outcome.applied.memoryGB) GB \
        and \(outcome.applied.cpuCount) processors.

        Setting memory and processors back to \(launch.memoryGB) GB and \(launch.cpuCount) restores \
        instant resume.
        """
        alert.alertStyle = .informational
        alert.beginSheetModal(for: window, completionHandler: nil)
    }

    @objc private func chooseSharedFolder() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: sharedFolderPath)
        panel.prompt = "Share"
        panel.message = "Choose the host folder the guest mounts over virtiofs."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            self.sharedFolderPath = url.path
            self.commit()
        }
    }

    @objc private func restoreDefaults() {
        let defaults = Settings.defaults.clamped()
        sharedFolderPath = defaults.sharedFolderPath
        memoryStepper.integerValue = defaults.memoryGB
        cpuStepper.integerValue = defaults.cpuCount
        rosettaCheck.state = defaults.enableRosetta ? .on : .off
        fullscreenCheck.state = defaults.startFullscreen ? .on : .off
        clipboardCheck.state = defaults.clipboardSyncEnabled ? .on : .off
        captureCheck.state = defaults.captureSystemKeys ? .on : .off
        commit()
    }

    @objc private func revealSettingsFile() {
        NSWorkspace.shared.activateFileViewerSelecting([Paths.settings])
    }

    // MARK: - NSWindowDelegate

    /// A slider released a fraction of a second before the window closed must
    /// still land.
    func windowWillClose(_ notification: Notification) {
        if commitTimer != nil { commit() }
    }
}
