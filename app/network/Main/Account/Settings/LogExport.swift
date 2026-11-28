//
//  LogExport.swift
//  URnetwork
//
//  Settings > Export Logs and View Logs: the logs "send feedback with logs"
//  uploads, to the share sheet, and their last lines
//  (https://github.com/urnetwork/apple/issues/223).
//
//  The export is the upload's own zip (SdkExportUploadLogs): the same files,
//  the newest glog files of the app and the packet tunnel extension under the
//  log root they share that fit the upload's cap, with the exit diagnostics
//  first, written by the sdk's upload writer. It is the zip the app's own
//  upload builds (FeedbackLogUpload, uploadFromApp), after the two steps that
//  upload takes first (prepareLogRoot). Like the upload, it holds the logs as
//  they were written. The developer bundle (DiagnosticExportService) is the
//  export with a choice of files, a manifest and redaction.
//
//  The zip is built when the share sheet asks for it (LogExportFile), and it is
//  a handoff, never storage: each export empties its folder in tmp first.
//

import Foundation
import SwiftUI
import CoreTransferable
import UniformTypeIdentifiers
import URnetworkSdk

enum LogExport {

    /// Exports go in their own folder of tmp, which each export empties: iOS
    /// purges tmp only under storage pressure, and an export can be tens of MB.
    static var exportDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("logs-export", isDirectory: true)
    }

    /// An export's file name, stamped in UTC like the developer bundle's, so
    /// names sort in time across devices and zones.
    static func fileName(date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return "urnetwork-logs-\(formatter.string(from: date)).zip"
    }

    /// Why an export has nothing to share.
    enum Failure: LocalizedError {
        case noLogs

        var errorDescription: String? {
            String(localized: "No log file found")
        }
    }

    /// Brings the newest lines into the app's log root, as the app's own upload
    /// does before it zips (FeedbackLogUpload.Steps): a running tunnel flushes
    /// its glog, and the direct-download build mirrors the system extension's
    /// logs, which it writes outside the app's root.
    static func prepareLogRoot() async {
        let steps = FeedbackLogUpload.Steps.live(device: nil, api: nil)
        await steps.requestExtensionFlush()
        steps.prepareAppLogRoot()
    }

    /// Writes the upload's zip into the export folder and returns it. It reads
    /// up to the upload's cap from disk, so it runs off the main actor.
    static func export(date: Date = Date()) async throws -> URL {
        await prepareLogRoot()
        let directory = exportDirectory
        // also collects a zip an export cut short left behind
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(fileName(date: date))

        var err: NSError?
        let result = SdkExportUploadLogs(destination.path, &err)
        if let err {
            print("[LogExport]export failed: \(err.localizedDescription)")
            throw err
        }
        // the sdk writes nothing when there is no log file
        guard let result, 0 < result.fileCount else {
            throw Failure.noLogs
        }
        return destination
    }

    /// The last lines of each process's newest log (SdkLogTails), after the
    /// same steps as the export, copied into swift values for the view.
    static func tails() async -> [LogTailSection] {
        await prepareLogRoot()
        guard let list = SdkLogTails() else { return [] }
        var sections: [LogTailSection] = []
        for i in 0..<list.len() {
            guard let tail = list.get(i) else { continue }
            var lines: [String] = []
            if let tailLines = tail.lines {
                lines.reserveCapacity(tailLines.len())
                for j in 0..<tailLines.len() {
                    lines.append(tailLines.get(j))
                }
            }
            sections.append(LogTailSection(
                id: sections.count,
                source: tail.source,
                name: tail.name,
                lines: lines,
                truncated: tail.truncated
            ))
        }
        return sections
    }
}

/// The end of one process's log: its last lines, oldest first, and whether the
/// log has lines before them.
struct LogTailSection: Identifiable {
    let id: Int
    /// the process that wrote the log, "app" or "extension"
    let source: String
    /// the log file's name
    let name: String
    let lines: [String]
    let truncated: Bool
}

/// The share sheet's item: the export, built when the sheet asks for the file.
struct LogExportFile: Transferable {

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .zip) { _ in
            let url = try await LogExport.export()
            return SentTransferredFile(url)
        }
    }
}

/// Settings' Export Logs row, on iOS and macOS: opens the share sheet with the
/// export.
struct ExportLogsRow: View {

    @EnvironmentObject var themeManager: ThemeManager

    var body: some View {
        ShareLink(
            item: LogExportFile(),
            preview: SharePreview(Text("Export Logs"))
        ) {
            HStack {
                Text("Export Logs")
                    .font(themeManager.currentTheme.bodyFont)
                    .foregroundColor(themeManager.currentTheme.textColor)
                Spacer()
                Image(systemName: "square.and.arrow.up")
                    .foregroundColor(themeManager.currentTheme.textMutedColor)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
