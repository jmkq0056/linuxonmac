import AppKit
import Foundation
import Virtualization

/// Two-way clipboard sync with the Linux guest.
///
/// Virtualization.framework provides clipboard sharing for macOS guests only, so
/// for a Linux guest it has to be built. This runs over vsock rather than TCP:
/// vsock is a direct host-guest channel that does not touch the network stack, so
/// the clipboard survives a broken guest network — which a host VPN with a small
/// MTU has already caused once on this machine.
///
/// Wire format is a 4-byte big-endian length followed by a JSON object, matching
/// `guest/clipboard-agent.py`.
final class ClipboardBridge {
    private let device: VZVirtioSocketDevice
    private let port: UInt32 = 7788
    private let maxBytes = 4 * 1024 * 1024

    private var connection: VZVirtioSocketConnection?
    private var pollTimer: Timer?
    private var readerThread: Thread?

    /// The pasteboard has no change notification, so `changeCount` is polled.
    /// It is a cheap integer read.
    private var lastChangeCount: Int = NSPasteboard.general.changeCount

    /// Text this side wrote locally, which must not be echoed back to the guest.
    private var suppressed: String?

    private(set) var isConnected = false {
        didSet {
            guard isConnected != oldValue else { return }
            onStateChange?(isConnected)
        }
    }

    /// Sync can be turned off from the menu without tearing down the connection.
    var isEnabled = true

    var onStateChange: ((Bool) -> Void)?

    init(device: VZVirtioSocketDevice) {
        self.device = device
    }

    // MARK: - Connection

    /// The guest agent may not be listening yet — it starts with the graphical
    /// session — so connection attempts repeat until one lands.
    func start() {
        Task { @MainActor in
            while connection == nil {
                do {
                    let established = try await device.connect(toPort: port)
                    adopt(established)
                    return
                } catch {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
            }
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        connection?.close()
        connection = nil
        isConnected = false
    }

    @MainActor
    private func adopt(_ established: VZVirtioSocketConnection) {
        connection = established
        isConnected = true
        Log.info("Clipboard bridge connected on vsock port \(port).")

        let descriptor = established.fileDescriptor
        let thread = Thread { [weak self] in self?.readLoop(descriptor: descriptor) }
        thread.name = "clipboard-reader"
        thread.start()
        readerThread = thread

        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.pushLocalChangeIfNeeded()
        }
    }

    @MainActor
    private func handleDisconnect() {
        guard connection != nil else { return }
        Log.warn("Clipboard bridge disconnected. Reconnecting.")
        stop()
        start()
    }

    // MARK: - macOS -> guest

    private func pushLocalChangeIfNeeded() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount

        guard isEnabled else { return }
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return }
        guard text.utf8.count <= maxBytes else {
            Log.warn("Clipboard content over \(maxBytes / 1024 / 1024) MB — not sent.")
            return
        }
        guard text != suppressed else { return }

        send(["t": "clip", "fmt": "text", "data": text])
    }

    /// Push the current pasteboard even if it has not changed — the menu's
    /// explicit "send now", for when sync is off or something got out of step.
    func pushNow() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        send(["t": "clip", "fmt": "text", "data": text])
    }

    private func send(_ payload: [String: String]) {
        guard let connection,
              let body = try? JSONSerialization.data(withJSONObject: payload)
        else { return }

        var header = UInt32(body.count).bigEndian
        var frame = Data(bytes: &header, count: 4)
        frame.append(body)

        let descriptor = connection.fileDescriptor
        frame.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if written <= 0 { return }
                offset += written
            }
        }
    }

    // MARK: - guest -> macOS

    private func readLoop(descriptor: Int32) {
        while true {
            guard let header = readExactly(descriptor: descriptor, count: 4) else { break }
            let length = header.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            guard length > 0, Int(length) <= maxBytes else { break }
            guard let body = readExactly(descriptor: descriptor, count: Int(length)) else { break }

            guard
                let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                object["t"] as? String == "clip",
                let text = object["data"] as? String
            else { continue }

            DispatchQueue.main.async { [weak self] in self?.applyFromGuest(text) }
        }
        DispatchQueue.main.async { [weak self] in self?.handleDisconnect() }
    }

    private func readExactly(descriptor: Int32, count: Int) -> Data? {
        var buffer = [UInt8](repeating: 0, count: count)
        var filled = 0
        while filled < count {
            let received = buffer.withUnsafeMutableBytes { raw in
                read(descriptor, raw.baseAddress!.advanced(by: filled), count - filled)
            }
            if received <= 0 { return nil }
            filled += received
        }
        return Data(buffer)
    }

    @MainActor
    private func applyFromGuest(_ text: String) {
        guard isEnabled else { return }
        guard text != NSPasteboard.general.string(forType: .string) else { return }

        // Record before writing: the write bumps changeCount, and without this
        // the poll would read it straight back and bounce it to the guest.
        suppressed = text
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        lastChangeCount = pasteboard.changeCount
    }
}
