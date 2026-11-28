//
//  LogExportTests.swift
//  networkTests
//
//  Settings > Export Logs (LogExport): the export's file name, and where it is
//  written. What the export holds is the sdk's upload zip, tested there
//  (sdk log_export_test.go).
//

import Testing
import Foundation
@testable import URnetwork

struct LogExportTests {

    @Test func fileNameIsStampedInUtcAndSortsInTime() {
        let name = LogExport.fileName(date: Date(timeIntervalSince1970: 1767225600))
        // pinned exactly: a name stamped in the device's own zone sorts wrongly
        // against one from another zone
        #expect(name == "urnetwork-logs-20260101-000000.zip")

        let earlier = LogExport.fileName(date: Date(timeIntervalSince1970: 1767225500))
        #expect(earlier < name)
    }

    @Test func exportsGoInTheirOwnFolderOfTmp() {
        // each export empties this folder, so it must never be tmp itself
        let directory = LogExport.exportDirectory
        #expect(directory.lastPathComponent == "logs-export")
        #expect(directory.deletingLastPathComponent().standardizedFileURL
            == FileManager.default.temporaryDirectory.standardizedFileURL)
    }
}
