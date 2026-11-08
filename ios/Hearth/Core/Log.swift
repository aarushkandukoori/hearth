// Tiny logger: os_log, plus Documents/hearth-console.log in developer runs (LaunchOptions.writesLogFile),
// which `ios/scripts/device.sh pull` copies off the phone. Normal use keeps no log file: even counts and
// timings, kept on disk, would be a diary of when someone talked to whom.
// Privacy rule: never pass user or character message text to this logger. Counts and timings only.

import Foundation
import os

enum HearthLog {
    private static let logger = Logger(subsystem: "com.aarushkandukoori.hearth", category: "app")
    private static let queue = DispatchQueue(label: "hearth.log")
    private static let writesFile = LaunchOptions.shared.writesLogFile
    private static let fileURL = HearthPaths.documents.appendingPathComponent("hearth-console.log")
    /// The developer log starts over past this size, so it can never fill the phone.
    private static let maxFileBytes: UInt64 = 1_048_576

    static func info(_ area: String, _ message: String) { write("INFO", area, message) }
    static func error(_ area: String, _ message: String) { write("ERROR", area, message) }
    static func debug(_ area: String, _ message: String) {
        guard LaunchOptions.shared.verbose else { return }
        write("DEBUG", area, message)
    }

    /// Prints a machine-readable line (e.g. "HEARTHBENCH {json}") to stdout and the log file.
    static func emit(_ line: String) {
        print(line)
        append(line)
    }

    private static func write(_ level: String, _ area: String, _ message: String) {
        let line = "\(timestamp()) [\(level)] [\(area)] \(message)"
        logger.log("\(line, privacy: .public)")
        print(line)
        append(line)
    }

    private static func append(_ line: String) {
        guard writesFile, let data = (line + "\n").data(using: .utf8) else { return }
        queue.async {
            // Only the throwing file calls: the older seekToEndOfFile() and write(_:) raise an Objective-C
            // exception (a crash on every launch) once the disk is full.
            do {
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                if try handle.seekToEnd() > maxFileBytes { try handle.truncate(atOffset: 0) }
                try handle.write(contentsOf: data)
            } catch {
                // No file yet: start one. One that can't be opened (iPhone locked) or a full disk loses the line.
                guard !FileManager.default.fileExists(atPath: fileURL.path) else { return }
                try? data.write(to: fileURL, options: [.atomic, .completeFileProtection])
                HearthPaths.setExcludedFromBackup(true, at: fileURL)
            }
        }
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: Date())
    }
}
