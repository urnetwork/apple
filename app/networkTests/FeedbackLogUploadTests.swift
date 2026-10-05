//
//  FeedbackLogUploadTests.swift
//  networkTests
//
//  "Send feedback with logs" (FeedbackLogUpload): which process uploads, the
//  order in which the app prepares its own upload, and, through the real sdk,
//  that either process's upload holds both processes' logs within the
//  server's size cap.
//
//  The sdk tests repoint this process's glog, which is process-global, so the
//  suite runs serially and puts the previous root back after each.
//

import Testing
import Foundation
import URnetworkSdk
@testable import URnetwork

@Suite(.serialized)
struct FeedbackLogUploadTests {

    // MARK: which process uploads

    /// Every step an upload takes, in order.
    private final class StepRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var steps: [String] = []

        func record(_ step: String) {
            lock.lock()
            defer { lock.unlock() }
            steps.append(step)
        }

        var recorded: [String] {
            lock.lock()
            defer { lock.unlock() }
            return steps
        }
    }

    /// The device rpc cannot carry the request: the tunnel is down.
    private struct RpcUnavailable: Error {}

    /// The app could not build its zip.
    private struct ZipUnavailable: Error {}

    private static func steps(
        recorder: StepRecorder,
        hasDevice: Bool,
        rpcAnswers: Bool,
        hasApi: Bool,
        appZipBuilds: Bool = true
    ) -> FeedbackLogUpload.Steps {
        FeedbackLogUpload.Steps(
            uploadThroughExtension: hasDevice ? { feedbackId in
                recorder.record("extension \(feedbackId)")
                if !rpcAnswers {
                    throw RpcUnavailable()
                }
            } : nil,
            requestExtensionFlush: {
                recorder.record("flush")
            },
            prepareAppLogRoot: {
                recorder.record("prepare")
            },
            uploadFromApp: hasApi ? { feedbackId in
                recorder.record("app \(feedbackId)")
                if !appZipBuilds {
                    throw ZipUnavailable()
                }
            } : nil
        )
    }

    /// The tunnel is up: the extension uploads, from outside the tunnel, and
    /// the app does not upload as well. The server takes one upload per
    /// network per 5 minutes, so a second would only be refused.
    @Test func whileTheTunnelIsUpTheExtensionUploadsAlone() async {
        let recorder = StepRecorder()
        let outcome = await FeedbackLogUpload.upload(
            feedbackId: "feedback-up",
            steps: Self.steps(recorder: recorder, hasDevice: true, rpcAnswers: true, hasApi: true)
        )
        #expect(outcome == .extensionProcess)
        #expect(recorder.recorded == ["extension feedback-up"])
    }

    /// The tunnel is down: the device rpc cannot ask the extension, which only
    /// failed before, so nothing was uploaded. The app uploads itself, after
    /// asking a running tunnel to flush and bringing the system extension's
    /// logs into its root.
    @Test func whileTheTunnelIsDownTheAppUploads() async {
        let recorder = StepRecorder()
        let outcome = await FeedbackLogUpload.upload(
            feedbackId: "feedback-down",
            steps: Self.steps(recorder: recorder, hasDevice: true, rpcAnswers: false, hasApi: true)
        )
        #expect(outcome == .appProcess)
        #expect(recorder.recorded == ["extension feedback-down", "flush", "prepare", "app feedback-down"])
    }

    /// No device (it could not be created, or the user is between logins): the
    /// app uploads without asking anything first.
    @Test func withoutADeviceTheAppUploads() async {
        let recorder = StepRecorder()
        let outcome = await FeedbackLogUpload.upload(
            feedbackId: "feedback-no-device",
            steps: Self.steps(recorder: recorder, hasDevice: false, rpcAnswers: false, hasApi: true)
        )
        #expect(outcome == .appProcess)
        #expect(recorder.recorded == ["flush", "prepare", "app feedback-no-device"])
    }

    /// An upload neither process could start is reported with both reasons.
    @Test func anUploadNeitherProcessCanStartIsReported() async {
        let recorder = StepRecorder()
        let outcome = await FeedbackLogUpload.upload(
            feedbackId: "feedback-failed",
            steps: Self.steps(recorder: recorder, hasDevice: true, rpcAnswers: false, hasApi: true, appZipBuilds: false)
        )
        guard case .failed(let reason) = outcome else {
            Issue.record("the upload was \(outcome), want failed")
            return
        }
        #expect(reason.hasPrefix("extension: "))
        #expect(reason.contains("; app: "))
        #expect(recorder.recorded == ["extension feedback-failed", "flush", "prepare", "app feedback-failed"])

        let nothing = await FeedbackLogUpload.upload(
            feedbackId: "feedback-nothing",
            steps: Self.steps(recorder: StepRecorder(), hasDevice: false, rpcAnswers: false, hasApi: false)
        )
        #expect(nothing == .failed("extension: no device; app: no api"))
    }

    /// The real steps ask only what exists.
    @Test func theLiveStepsAskOnlyWhatExists() {
        let steps = FeedbackLogUpload.Steps.live(device: nil, api: nil)
        #expect(steps.uploadThroughExtension == nil)
        #expect(steps.uploadFromApp == nil)
    }

    // …/apple/app/networkTests/FeedbackLogUploadTests.swift -> …/apple/app
    private static let appRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static func source(_ path: String) throws -> String {
        try String(contentsOf: appRoot.appendingPathComponent(path), encoding: .utf8)
    }

    /// The feedback screen goes through the routing, not straight to the
    /// device, which was the whole of the upload before.
    @Test func theFeedbackScreenUploadsThroughTheRouting() throws {
        let deviceManager = try Self.source("network/Shared/ViewModels/DeviceManager.swift")
        #expect(deviceManager.contains("FeedbackLogUpload.Steps.live(device: device, api: api)"))
        #expect(deviceManager.contains("await FeedbackLogUpload.upload(feedbackId: feedbackId, steps: steps)"))
        #expect(!deviceManager.contains("device?.uploadLogs("))

        let feedbackView = try Self.source("network/Main/Feedback/FeedbackView.swift")
        #expect(feedbackView.contains("deviceManager.uploadLogs(feedbackId: feedbackIdStr)"))
    }

    // MARK: what the upload holds, through the real sdk

    /// A log root laid out like the App Group's Logs, with this process's glog
    /// pointed at `processName` under it for the duration of `body`. The
    /// previous root is put back afterwards, as the app's own process.
    private static func withLogRoot(processName: String, _ body: (URL) throws -> Void) throws {
        let fileManager = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("feedback-log-upload-test-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: root)
        }

        let previousRoot = SdkGetLogRoot()
        var err: NSError?
        SdkSetLogDirForProcess(root.path, processName, &err)
        #expect(err == nil)
        defer {
            if !previousRoot.isEmpty {
                var restoreError: NSError?
                SdkSetLogDirForProcess(previousRoot, DiagnosticsLogContract.appProcessName, &restoreError)
            }
        }

        try body(root)
    }

    /// Writes a file with a glog name into `<root>/<source>`, `byteCount`
    /// bytes long (sparse, so a large one takes no disk), modified at
    /// `modified`.
    private static func writeLogFile(
        root: URL,
        source: String,
        name: String,
        byteCount: UInt64,
        modified: Date
    ) throws {
        let fileManager = FileManager.default
        let directory = root.appendingPathComponent(source, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        #expect(fileManager.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: byteCount)
        try handle.close()
        try fileManager.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }

    /// What an upload from this process would send now.
    private static func uploadInventory() -> [SdkLogFileInfo] {
        guard let list = SdkUploadLogsInventory() else { return [] }
        var infos: [SdkLogFileInfo] = []
        for i in 0..<list.len() {
            if let info = list.get(i) {
                infos.append(info)
            }
        }
        return infos
    }

    private static func sourceNames(_ infos: [SdkLogFileInfo]) -> [String] {
        infos.map { "\($0.source)/\($0.name)" }
    }

    /// The tunnel is down and the app uploads: its zip holds the extension's
    /// logs from the last tunnel as well as the app's own, and nothing else
    /// that sits in the log directories.
    @Test func whileTheTunnelIsDownTheAppsUploadHoldsBothProcesses() throws {
        try Self.withLogRoot(processName: DiagnosticsLogContract.appProcessName) { root in
            let hourAgo = Date().addingTimeInterval(-3600)
            try Self.writeLogFile(root: root, source: "app", name: "urnetwork.test.user.log.INFO.20260901-000000.11",
                                  byteCount: 64, modified: hourAgo)
            try Self.writeLogFile(root: root, source: "extension", name: "urnetwork.test.user.log.INFO.20260901-000000.22",
                                  byteCount: 64, modified: hourAgo)
            try Self.writeLogFile(root: root, source: "extension", name: "notes.txt",
                                  byteCount: 64, modified: hourAgo)

            let sourceNames = Self.sourceNames(Self.uploadInventory())
            #expect(sourceNames.contains("app/urnetwork.test.user.log.INFO.20260901-000000.11"))
            #expect(sourceNames.contains("extension/urnetwork.test.user.log.INFO.20260901-000000.22"))
            #expect(!sourceNames.contains("extension/notes.txt"))
            #expect(sourceNames.allSatisfy { $0.hasPrefix("app/") || $0.hasPrefix("extension/") })
        }
    }

    /// The tunnel is up and the extension uploads: its zip, built from the
    /// same root, holds the app's logs, which an upload of the extension's own
    /// directory never did.
    @Test func whileTheTunnelIsUpTheExtensionsUploadHoldsTheAppsLogs() throws {
        try Self.withLogRoot(processName: DiagnosticsLogContract.extensionProcessName) { root in
            let hourAgo = Date().addingTimeInterval(-3600)
            try Self.writeLogFile(root: root, source: "app", name: "urnetwork.test.user.log.INFO.20260901-000000.33",
                                  byteCount: 64, modified: hourAgo)

            let infos = Self.uploadInventory()
            #expect(Self.sourceNames(infos).contains("app/urnetwork.test.user.log.INFO.20260901-000000.33"))
            #expect(infos.contains { $0.source == DiagnosticsLogContract.extensionProcessName })
        }
    }

    /// The server keeps a log zip only up to 100 MiB and drops a larger one
    /// whole, while each process keeps up to 4 files of 16 MiB at a start and
    /// more as files fill. The upload holds the newest files that fit its cap,
    /// whichever process wrote them.
    @Test func theUploadStaysWithinTheServersCap() throws {
        try Self.withLogRoot(processName: DiagnosticsLogContract.appProcessName) { root in
            let mebibyte: UInt64 = 1024 * 1024
            let now = Date()
            try Self.writeLogFile(root: root, source: "extension", name: "urnetwork.test.user.log.INFO.20260901-000000.41",
                                  byteCount: 40 * mebibyte, modified: now.addingTimeInterval(-1 * 3600))
            try Self.writeLogFile(root: root, source: "app", name: "urnetwork.test.user.log.INFO.20260901-000000.42",
                                  byteCount: 40 * mebibyte, modified: now.addingTimeInterval(-2 * 3600))
            try Self.writeLogFile(root: root, source: "app", name: "urnetwork.test.user.log.INFO.20260901-000000.43",
                                  byteCount: 40 * mebibyte, modified: now.addingTimeInterval(-3 * 3600))
            try Self.writeLogFile(root: root, source: "extension", name: "urnetwork.test.user.log.INFO.20260901-000000.44",
                                  byteCount: 40 * mebibyte, modified: now.addingTimeInterval(-4 * 3600))

            let infos = Self.uploadInventory()
            let sourceNames = Self.sourceNames(infos)
            #expect(sourceNames.contains("extension/urnetwork.test.user.log.INFO.20260901-000000.41"))
            #expect(sourceNames.contains("app/urnetwork.test.user.log.INFO.20260901-000000.42"))
            #expect(!sourceNames.contains("app/urnetwork.test.user.log.INFO.20260901-000000.43"))
            #expect(!sourceNames.contains("extension/urnetwork.test.user.log.INFO.20260901-000000.44"))

            let byteCount = infos.reduce(Int64(0)) { $0 + $1.byteCount }
            #expect(byteCount <= 100 * 1024 * 1024)
        }
    }
}
