import Foundation

enum SyncDiagnosticsLogger {
    private static let maxBytes = 256_000
    private static let queue = DispatchQueue(label: "HomeFloorplan.SyncDiagnosticsLogger")

    static var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HomeFloorplan-SyncDiagnostics.log")
    }

    static func log(_ message: String) {
        let line = "\(Self.timestamp()) \(message)\n"
        queue.async {
            do {
                try rotateIfNeeded()
                let data = Data(line.utf8)
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    let handle = try FileHandle(forWritingTo: fileURL)
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                    try handle.close()
                } else {
                    try data.write(to: fileURL, options: .atomic)
                }
            } catch {
                #if DEBUG
                print("[SyncDiagnostics] write failed: \(error)")
                #endif
            }
        }
    }

    static func clear() {
        queue.async {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    private static func rotateIfNeeded() throws {
        guard let size = try? FileManager.default
            .attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber,
              size.intValue > maxBytes
        else { return }

        let data = (try? Data(contentsOf: fileURL)) ?? Data()
        let suffix = data.suffix(maxBytes / 2)
        try Data(suffix).write(to: fileURL, options: .atomic)
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}
