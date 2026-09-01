//
//  DiagnosticExportServiceTests.swift
//  networkTests
//
//  Covers the exported bundle: its file name (sortable, and honest about
//  whether it was redacted, so a redacted bundle is never mistaken for a
//  complete one), what the UI says about it before and after, and -- through
//  the real SDK -- that "export selected" exports exactly what was selected.
//

import Testing
import Foundation
import URnetworkSdk
@testable import URnetwork

struct DiagnosticExportServiceTests {

    @Test func bundleNameIsSortableAndCarriesTheMode() {
        let date = Date(timeIntervalSince1970: 1767225600)
        let raw = DiagnosticExportService.bundleFileName(date: date, redacted: false)
        let redacted = DiagnosticExportService.bundleFileName(date: date, redacted: true)

        #expect(raw.hasPrefix("urnetwork-diagnostics-"))
        #expect(raw.hasSuffix(".zip"))
        #expect(redacted.contains("redacted"))
        #expect(!raw.contains("redacted"))
        // the stamp is UTC, so bundles made either side of a timezone change
        // still sort in the order they were made
        #expect(raw.contains("20260101-000000"))

        let earlier = DiagnosticExportService.bundleFileName(
            date: Date(timeIntervalSince1970: 1767225500), redacted: false)
        #expect(earlier < raw)
    }

    @Test func rowLabelNamesTheSourceSeverityAndSize() {
        let label = DiagnosticExportService.rowLabel(source: "extension", severity: "ERROR", byteCount: 2048)
        #expect(label.contains("extension"))
        #expect(label.contains("ERROR"))
        #expect(label.contains("KiB"))

        // a freshly rotated file is not empty, and must not read as if it were
        // -- `byteCount / 1024` rendered a 400 byte log as "0 KiB"
        #expect(DiagnosticExportService.sizeLabel(400) == "400 B")
        #expect(DiagnosticExportService.sizeLabel(0) == "0 B")
    }

    @Test func inventoryLabelReportsTheTotalBeforeExporting() {
        #expect(DiagnosticExportService.inventoryLabel(fileCount: 0, byteCount: 0)
                == "No log files on disk")
        let label = DiagnosticExportService.inventoryLabel(fileCount: 3, byteCount: 4 * 1024 * 1024)
        #expect(label.contains("3 log files"))
        #expect(label.contains("4.00 MiB"))
        #expect(DiagnosticExportService.inventoryLabel(fileCount: 1, byteCount: 1024)
                .contains("1 log file "))

        // the picker's own total, for the subset that is checked
        #expect(DiagnosticExportService.selectionLabel(fileCount: 0, byteCount: 0)
                == "Nothing selected")
        #expect(DiagnosticExportService.selectionLabel(fileCount: 2, byteCount: 2048)
                == "Selected 2 files · 2.00 KiB")
    }

    /// The summary of a finished export is the last thing read before the
    /// bundle is sent on, and it reported "Exported 1 log files".
    @Test func theExportSummaryCountsInSingularAndPlural() {
        #expect(DiagnosticExportService.exportSummaryLabel(fileCount: 1, byteCount: 1024)
                == "Exported 1 log file (1.00 KiB)")
        #expect(DiagnosticExportService.exportSummaryLabel(fileCount: 2, byteCount: 2048)
                == "Exported 2 log files (2.00 KiB)")
        // an empty bundle is plural, like every other zero-count label here
        #expect(DiagnosticExportService.exportSummaryLabel(fileCount: 0, byteCount: 0)
                == "Exported 0 log files (0 B)")
    }

    @Test func exportSelectionIsBlockedWithNothingChecked() {
        // An empty `selectedNames` means "no filter" to the SDK -- the same
        // as "Export all logs" -- so "Export selected" must refuse to run
        // rather than silently exporting everything unredacted.
        #expect(DiagnosticExportService.canExportSelection([]) == false)
        #expect(DiagnosticExportService.canExportSelection(["app.log"]) == true)
        #expect(DiagnosticExportService.canExportSelection(["app.log", "extension.log"]) == true)
    }

    /// An unreachable source has to be recorded as missing, never silently
    /// dropped. The entitlement being absent was the only case being
    /// reported, so in the
    /// ordinary ones -- the tunnel has never run on this install, the
    /// extension could not write to the group -- the bundle shipped with only
    /// logs/app/ and nothing anywhere saying the extension was left out.
    @Test func anAbsentSourceIsReportedEvenWhenTheAppGroupResolves() {
        #expect(DiagnosticExportService.missingSources(
            sharedRootUnavailableReason: nil,
            inventorySources: ["app", "extension"]
        ).isEmpty)

        let absent = DiagnosticExportService.missingSources(
            sharedRootUnavailableReason: nil,
            inventorySources: ["app"]
        )
        #expect(absent.count == 1)
        #expect(absent.first?.source == "extension")
        #expect(absent.first?.reason.contains("tunnel has not run") == true)

        // the container reason wins when there is one, and is passed through
        // verbatim so the bundle says which of the two it was
        #expect(DiagnosticExportService.missingSources(
            sharedRootUnavailableReason: "app group container unavailable in this build",
            inventorySources: ["app"]
        ).first?.reason == "app group container unavailable in this build")

        // ... and it is reported even if an extension directory somehow
        // survives from an earlier build that did have the group
        #expect(DiagnosticExportService.missingSources(
            sharedRootUnavailableReason: "app group container unavailable in this build",
            inventorySources: ["app", "extension"]
        ).count == 1)

        // the app's own logs are a source too: the SDK swallows a directory
        // read failure entirely, so this is the only place their absence can
        // be noticed
        let noApp = DiagnosticExportService.missingSources(
            sharedRootUnavailableReason: nil,
            inventorySources: []
        )
        #expect(noApp.count == 2)
        #expect(noApp.first?.source == "app")

        #expect(DiagnosticExportService.unavailableSourceLabel(
            source: "extension", reason: "no log directory on disk")
                == "Not available: extension: no log directory on disk")
    }

    @Test func rowIdentityIsQualifiedBySourceAndTotalsAreSummed() {
        // the SDK's own selection filter matches the bare name, and its doc
        // comment calls it unique across the export, but nothing enforces that
        // across per-process directories -- and two rows sharing a SwiftUI id
        // is a diffing hazard, not a cosmetic one
        let appInfo = SdkLogFileInfo()
        appInfo.name = "urnetwork.log.INFO"
        appInfo.source = "app"
        appInfo.severity = "INFO"
        appInfo.byteCount = 2048
        let extensionInfo = SdkLogFileInfo()
        extensionInfo.name = "urnetwork.log.INFO"
        extensionInfo.source = "extension"
        extensionInfo.severity = "INFO"
        extensionInfo.byteCount = 1024

        #expect(appInfo.pickerRowId != extensionInfo.pickerRowId)
        #expect(appInfo.pickerRowId == "app/urnetwork.log.INFO")
        #expect(DiagnosticExportService.sources(of: [appInfo, extensionInfo]) == ["app", "extension"])
        #expect(DiagnosticExportService.totalByteCount(of: [appInfo, extensionInfo]) == 3072)
        #expect(DiagnosticExportService.sources(of: []).isEmpty)
    }

    @Test func pickerRowsCarryTheModifiedTime() {
        // picker rows show severity, size AND modified time -- the modified
        // time is what distinguishes the live file from last week's rotation
        let label = DiagnosticExportService.rowLabel(
            source: "app", severity: "INFO", byteCount: 2048, modifiedMillis: 1767225600000)
        #expect(label.contains("2026-01-01 00:00Z"))
        // unknown (the SDK reports 0) leaves the row shorter rather than
        // claiming the epoch
        #expect(!DiagnosticExportService.rowLabel(
            source: "app", severity: "INFO", byteCount: 2048, modifiedMillis: 0).contains("1970"))
    }

    /// End-to-end across the gomobile bind, against the real SDK: the picker's
    /// entire contract is `SelectedNames`, whose documented semantic is that
    /// EMPTY means every file. Getting the filter inverted or off by one turns
    /// "export these two" into "export everything", so this exercises it with
    /// a real log root, a real zip, and a name that is not selected.
    ///
    /// Repoints this process's glog, which is process-global, so it restores
    /// the previous root before returning.
    @Test func exportSelectedWritesOnlyTheSelectedFileAndPrunesTheLastBundle() throws {
        let fileManager = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("diagnostics-test-\(UUID().uuidString)", isDirectory: true)
        let appDirectory = root.appendingPathComponent(
            DiagnosticsLogContract.appProcessName, isDirectory: true)
        try fileManager.createDirectory(at: appDirectory, withIntermediateDirectories: true)

        let selectedName = "urnetwork.test.log.INFO.20260830-000000.1"
        let unselectedName = "urnetwork.test.log.ERROR.20260830-000000.1"
        try "selected line\n".write(
            to: appDirectory.appendingPathComponent(selectedName), atomically: true, encoding: .utf8)
        try "unselected line\n".write(
            to: appDirectory.appendingPathComponent(unselectedName), atomically: true, encoding: .utf8)

        let previousRoot = SdkGetLogRoot()
        var err: NSError?
        SdkSetLogDirForProcess(root.path, DiagnosticsLogContract.appProcessName, &err)
        #expect(err == nil)
        defer {
            if !previousRoot.isEmpty {
                var restoreError: NSError?
                SdkSetLogDirForProcess(
                    previousRoot, DiagnosticsLogContract.appProcessName, &restoreError)
            }
        }

        let inventoryNames = Set(DiagnosticExportService.inventory().map { $0.name })
        #expect(inventoryNames.contains(selectedName))
        #expect(inventoryNames.contains(unselectedName))

        let first = try DiagnosticExportService.export(
            redacted: false,
            selectedNames: [selectedName],
            device: nil,
            sharedRootUnavailableReason: nil,
            date: Date(timeIntervalSince1970: 1767225600)
        )

        let zip = try Data(contentsOf: first.url)
        #expect(contains(zip, "logs/app/\(selectedName)"))
        #expect(!contains(zip, "logs/app/\(unselectedName)"))
        #expect(contains(zip, "manifest.json"))
        // no extension logs under this root, so the bundle must say so rather
        // than looking like the extension had nothing to report
        #expect(first.summary.contains("Not included"))

        // a new export clears the last one: iOS purges tmp only under storage
        // pressure, and each bundle can hold up to 4x16MB of logs per process
        let second = try DiagnosticExportService.export(
            redacted: true,
            selectedNames: [selectedName],
            device: nil,
            sharedRootUnavailableReason: nil,
            date: Date(timeIntervalSince1970: 1767225700)
        )
        #expect(second.url != first.url)
        #expect(fileManager.fileExists(atPath: second.url.path))
        #expect(!fileManager.fileExists(atPath: first.url.path))

        try? fileManager.removeItem(at: DiagnosticExportService.bundleDirectory)
    }

    private func contains(_ data: Data, _ text: String) -> Bool {
        // zip entry names are stored uncompressed in the local and central
        // headers, so this reads the archive's layout without needing an
        // unzip implementation in the test target
        data.range(of: Data(text.utf8)) != nil
    }
}
