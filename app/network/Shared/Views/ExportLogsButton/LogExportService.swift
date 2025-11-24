//
//  LogExportService.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 11/18/25.
//

import Foundation
import URnetworkSdk

enum LogExportService {

    static func generateShareableURL() throws -> URL {

        // flush logs
        SdkFlushGlog()

        guard let logDir = logDirectory() else {
            return try writeAdHocLog("No log directory available.")
        }

        let fm = FileManager.default
        guard fm.fileExists(atPath: logDir.path) else {
            return try writeAdHocLog("Log directory does not exist at \(logDir.path).")
        }

        // find most recent log file
        let files = try fm.contentsOfDirectory(
            at: logDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        let regularFiles = try files.filter {
            (try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }

        guard let newest = try regularFiles.max(by: {
            let a = try $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
            let b = try $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
            return a < b
        }) else {
            return try writeAdHocLog("No log files found in \(logDir.path).")
        }

        return try copyToTempWithLogExtension(newest)
    }

    static func logDirectory() -> URL? {
        let raw = SdkGetLogDir()
        guard !raw.isEmpty else { return nil }
        return URL(fileURLWithPath: raw, isDirectory: true)
    }

    static func suggestedFilename(for url: URL) -> String {
        url.lastPathComponent
    }

    /// copies the source log file to a temp .log file with a timestamped name.
    private static func copyToTempWithLogExtension(_ source: URL) throws -> URL {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let dateStr = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let dest = tmp.appendingPathComponent("URnetwork-\(dateStr).log")

        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) {
            try? fm.removeItem(at: dest)
        }
        try fm.copyItem(at: source, to: dest)
        return dest
    }

    /// Writes a fallback log file with the given contents to temp and returns its URL.
    private static func writeAdHocLog(_ contents: String) throws -> URL {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let dest = tmp.appendingPathComponent("URnetwork.log")
        try contents.write(to: dest, atomically: true, encoding: .utf8)
        return dest
    }
}
