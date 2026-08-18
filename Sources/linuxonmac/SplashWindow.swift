import AppKit

/// The stages a launch actually goes through.
///
/// Each one is set from a real transition in `VMSession` — nothing here advances
/// on a timer, so the line on screen is always the thing the app is genuinely
/// waiting on rather than a progress bar performing progress.
enum LaunchPhase {
    case startingMachine
    case resumingState
    case bootingGuest
    case connectingClipboard

    var message: String {
        switch self {
        case .startingMachine: return "Starting virtual machine"
        case .resumingState: return "Resuming saved state"
        case .bootingGuest: return "Booting Debian"
        case .connectingClipboard: return "Connecting clipboard bridge"
        }
    }
}

/// A borderless panel shown while the guest comes up, dismissed by the event
/// that means the guest is usable — the clipboard bridge connecting, which only
/// happens once the graphical session is running.
final class SplashWindow: NSObject {
    private let window: NSWindow
    private let status = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private var fallback: Timer?
    private var isDismissed = false

    private let width: CGFloat = 340

    init(subtitle: String) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 250),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        super.init()

        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .floating
        window.isMovableByWindowBackground = true
        // The VM window spends its life fullscreen on its own Space. Without
        // these the splash would be left behind on the Space the app launched
        // from, describing a boot nobody can see.
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        // NSVisualEffectView tracks the system appearance on its own, so light
        // and dark both look deliberate without a second set of colours here.
        let backdrop = NSVisualEffectView()
        backdrop.material = .popover
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = 18
        backdrop.layer?.masksToBounds = true
        window.contentView = backdrop

        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = 8
        column.edgeInsets = NSEdgeInsets(top: 26, left: 22, bottom: 22, right: 22)
        column.translatesAutoresizingMaskIntoConstraints = false

        if let icon = Self.applicationIcon() {
            let view = NSImageView(image: icon)
            view.imageScaling = .scaleProportionallyUpOrDown
            view.widthAnchor.constraint(equalToConstant: 88).isActive = true
            view.heightAnchor.constraint(equalToConstant: 88).isActive = true
            column.addArrangedSubview(view)
        }

        let title = NSTextField(labelWithString: Self.applicationName())
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.textColor = .labelColor
        title.alignment = .center
        column.addArrangedSubview(title)

        let detail = NSTextField(labelWithString: subtitle)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .center
        column.addArrangedSubview(detail)
        column.setCustomSpacing(20, after: detail)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.widthAnchor.constraint(equalToConstant: 16).isActive = true
        spinner.heightAnchor.constraint(equalToConstant: 16).isActive = true

        status.font = .systemFont(ofSize: 12)
        status.textColor = .labelColor
        status.lineBreakMode = .byTruncatingTail

        let row = NSStackView(views: [spinner, status])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        column.addArrangedSubview(row)

        backdrop.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
            column.topAnchor.constraint(equalTo: backdrop.topAnchor)
        ])
        backdrop.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: width, height: ceil(column.fittingSize.height)))

        let click = NSClickGestureRecognizer(target: self, action: #selector(dismissFromClick))
        backdrop.addGestureRecognizer(click)
    }

    // MARK: - The real app icon

    /// The bundle's own icon, never a substitute. If neither lookup works the
    /// splash simply has no icon — an empty space is more honest than a glyph
    /// that is not this app.
    private static func applicationIcon() -> NSImage? {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
    }

    private static func applicationName() -> String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "linuxonmac"
    }

    // MARK: - Lifecycle

    func show(phase: LaunchPhase) {
        update(phase: phase)
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            window.setFrameOrigin(NSPoint(
                x: visible.midX - window.frame.width / 2,
                y: visible.midY - window.frame.height / 2 + visible.height * 0.07
            ))
        }
        window.alphaValue = 0
        // Ordered front rather than made key: the VM view has to keep first
        // responder or the first keystrokes after boot go nowhere.
        window.orderFrontRegardless()
        spinner.startAnimation(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            window.animator().alphaValue = 1
        }
    }

    func update(phase: LaunchPhase) {
        guard !isDismissed else { return }
        status.stringValue = phase.message
    }

    /// A guest without the clipboard agent installed never connects, and the
    /// splash must not outlive the boot it is describing.
    func armFallbackDismiss(after seconds: TimeInterval) {
        guard !isDismissed, fallback == nil else { return }
        fallback = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            self?.dismiss()
        }
    }

    func dismiss() {
        guard !isDismissed else { return }
        isDismissed = true
        fallback?.invalidate()
        fallback = nil
        spinner.stopAnimation(nil)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            window.animator().alphaValue = 0
        }, completionHandler: { [window] in
            window.orderOut(nil)
        })
    }

    @objc private func dismissFromClick() { dismiss() }
}
