import Foundation

/// Temporary file-based diagnostics. Deliberately not os_log/NSLog: those
/// redact interpolated values as <private> in the system log by default,
/// which makes them useless for inspecting what was actually typed.
enum DebugLog {
    private static let url = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("englishautocorrect-debug.log")
    private static let queue = DispatchQueue(label: "debuglog")

    static func write(_ message: String) {
        queue.async {
            let line = "\(Date().timeIntervalSince1970) \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
}
