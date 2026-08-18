import Foundation

/// Logs go to stdout for terminal runs and to a file for detached launches
/// (via `open`), where stdout is discarded by LaunchServices.
enum Log {
    static let fileURL: URL = Paths.bundle
        .deletingLastPathComponent()
        .appendingPathComponent("linuxonmac.log")

    private static let handle: FileHandle? = {
        let path = fileURL.path
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        let handle = try? FileHandle(forWritingTo: fileURL)
        try? handle?.seekToEnd()
        return handle
    }()

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    static func info(_ message: String) { emit("", message, toStderr: false) }
    static func warn(_ message: String) { emit("warning: ", message, toStderr: false) }
    static func error(_ message: String) { emit("error: ", message, toStderr: true) }

    private static func emit(_ prefix: String, _ message: String, toStderr: Bool) {
        let line = "[\(stamp.string(from: Date()))] \(prefix)\(message)\n"
        if toStderr {
            FileHandle.standardError.write(Data(line.utf8))
        } else {
            FileHandle.standardOutput.write(Data(line.utf8))
        }
        try? handle?.write(contentsOf: Data(line.utf8))
    }
}
