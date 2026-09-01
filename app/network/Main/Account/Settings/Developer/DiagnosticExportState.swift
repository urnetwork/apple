//
//  DiagnosticExportState.swift
//  URnetwork
//
//  The diagnostics export, and everything the developer screen shows about it,
//  held outside the view.
//
//  It lives here rather than in `DeveloperView`'s `@State` because an export
//  outlives the screen: the work is a detached task, and navigating back to
//  Settings and into Developer again re-creates the view. With the in-flight
//  flag in the view, that re-created view had `isExporting == false` and would
//  happily start a second export on top of the first -- both writing a
//  destination named at one-second resolution, so two exports of the same mode
//  in the same second raced on the same path and corrupted the zip that then
//  went to support. Holding it here also means the finished bundle is still
//  offered to share when the user comes back, instead of being written to disk
//  and silently dropped.
//

import Foundation
import URnetworkSdk

final class DiagnosticExportState: ObservableObject {

    /// One export at a time per process, so the guard cannot be reset by
    /// leaving the screen.
    static let shared = DiagnosticExportState()

    @Published private(set) var isExporting = false
    @Published private(set) var bundle: URL?
    @Published private(set) var summary: String?
    @Published private(set) var errorMessage: String?

    @Published private(set) var inventory: [SdkLogFileInfo] = []
    @Published private(set) var inventoryLabel: String?
    /// Shown BEFORE an export, not only in the summary afterwards: an
    /// unavailable source and its reason have to be visible in the export UI,
    /// and by the time they appear in a completed export's summary the user
    /// has already committed to it.
    @Published private(set) var unavailableSources: [String] = []

    /// Reads the on-disk inventory off the main thread and publishes the
    /// totals. `SdkLogInventory()` is an os.ReadDir plus a Stat per file over
    /// the app group container through a cgo hop that can also block on a Go
    /// GC stop-the-world, which is not work for the main actor.
    @MainActor
    func refreshInventory(sharedRootUnavailableReason: String?) async {
        let infos = await Task.detached(priority: .userInitiated) {
            DiagnosticExportService.inventory()
        }.value

        inventory = infos
        inventoryLabel = DiagnosticExportService.inventoryLabel(
            fileCount: infos.count,
            byteCount: DiagnosticExportService.totalByteCount(of: infos)
        )
        unavailableSources = DiagnosticExportService.missingSources(
            sharedRootUnavailableReason: sharedRootUnavailableReason,
            inventorySources: DiagnosticExportService.sources(of: infos)
        ).map { DiagnosticExportService.unavailableSourceLabel(source: $0.source, reason: $0.reason) }
    }

    /**
     * `DiagnosticExportService.export` is a synchronous worker: it reads and
     * DEFLATE-compresses up to 4 log files of up to 16MB each into a zip, per
     * process, with a per-line redaction pass in the redacted mode. Running it
     * inline from a Button action would put all of that on the main actor --
     * freezing the UI and risking an iOS watchdog kill on a slow device. So it
     * is pushed onto a detached task, and the published result is written back
     * only after the `await`, which resumes on the main actor.
     *
     * Everything the worker needs is read here, before the hop, rather than
     * inside the detached closure -- reading `deviceManager.device` off the
     * main actor would itself be unsafe.
     */
    @MainActor
    func export(
        redacted: Bool,
        selected: [String],
        device: SdkDeviceRemote?,
        sharedRootUnavailableReason: String?
    ) async {
        guard !isExporting else { return }
        isExporting = true
        errorMessage = nil

        // the manifest rpc reaches the extension, but nothing in it flushes
        // the extension's glog, so ask for that first: otherwise the newest
        // extension lines -- the ones describing whatever is being reported --
        // are still buffered in the extension when these files are read
        await TunnelDiagnosticsFlush.requestExtensionFlush()

        let outcome = await Task.detached(priority: .userInitiated) {
            Result {
                try DiagnosticExportService.export(
                    redacted: redacted,
                    selectedNames: selected,
                    device: device,
                    sharedRootUnavailableReason: sharedRootUnavailableReason
                )
            }
        }.value

        isExporting = false
        switch outcome {
        case .success(let export):
            bundle = export.url
            summary = export.summary
            errorMessage = nil
        case .failure(let error):
            bundle = nil
            summary = nil
            errorMessage = "Export failed: \(error.localizedDescription)"
        }

        await refreshInventory(sharedRootUnavailableReason: sharedRootUnavailableReason)
    }
}
