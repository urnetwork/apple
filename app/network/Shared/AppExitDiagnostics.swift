//
//  AppExitDiagnostics.swift
//  URnetwork
//
//  Why the app's earlier processes ended, for "send feedback with logs"
//  (support 8190: "the app closes by itself after a while").
//
//  A crash, a hang the system ended, a memory or cpu limit and the user all
//  look the same to a user, and only the system knows which. MetricKit tells
//  the app: a diagnostic payload for each crash, hang, cpu or disk write
//  exception and slow launch (at the next launch on iOS 15+ and macOS 12+),
//  and a metric payload about once a day whose exit metric counts the app's
//  exits by reason, in the foreground and in the background. A memory limit
//  kill makes no crash report: only those counts show it. Android logs its
//  process exit records at start the same way (ProcessExitDiagnostics).
//
//  This hands each payload's json to the sdk (SdkLogMetricKitDiagnosticPayload,
//  SdkLogMetricKitMetricPayload), which does the rest
//  (sdk/exit_diagnostics_metrickit.go): it keeps the exit's kind, exception
//  type and code, signal, a sanitized and bounded termination reason, the app
//  and os versions, the time range and the exit counts -- never a call stack,
//  an address, a path or an identifier -- as one line per record in the exit
//  diagnostics file of the app's log directory, Logs/app/exit-diagnostics.txt
//  (DiagnosticsLogLocation), and records what it logged so that a payload is
//  logged once. The sdk's feedback upload carries that file beside the glog
//  files, from either process (FeedbackLogUpload).
//
//  Nothing new leaves the device: the file goes out only inside "send
//  feedback with logs", which the user chooses to send.
//
//  MetricKit hands the subscriber what is new; the payloads it kept from
//  before this start are read once at start too, so a build that has just
//  added this logs the last days at once. The sdk skips one it has logged.
//
//  Best effort by construction: nothing here throws, the payloads are handled
//  off the main thread on a queue of their own, and a failure leaves a payload
//  unlogged. A diagnostic must never be what breaks a launch.
//

import Foundation
import URnetworkSdk
#if canImport(MetricKit)
import MetricKit
#endif

#if canImport(MetricKit)

/// The app process's MetricKit subscriber: one per process, started at
/// launch, which hands every payload to the sdk.
final class AppExitDiagnostics: NSObject, MXMetricManagerSubscriber {

    /// The one subscriber, so that a payload is never handed over twice.
    static let shared = AppExitDiagnostics()

    /// One payload at a time, in the order they come: the sdk reads and
    /// writes the file and its record for each.
    private let queue = DispatchQueue(label: "network.ur.exit-diagnostics", qos: .utility)

    /// Whether start has run. Main thread only.
    private var started = false

    /// Only `shared`.
    private override init() {
        super.init()
    }

    /// Subscribes to MetricKit and logs the payloads it kept from before this
    /// start. Call once, on the main thread, after the app's log directory is
    /// configured (DiagnosticsLogLocation.configure): the sdk writes into it.
    func start() {
        guard !started else {
            return
        }
        started = true
        MXMetricManager.shared.add(self)
        queue.async {
            let metricManager = MXMetricManager.shared
            Self.log(diagnosticPayloads: metricManager.pastDiagnosticPayloads)
            Self.log(metricPayloads: metricManager.pastPayloads)
        }
    }

    // MARK: MXMetricManagerSubscriber, called on a background queue

    /// New crash, hang, cpu, disk write and launch diagnostics: at the next
    /// launch after a crash on iOS 15+ and macOS 12+.
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        queue.async {
            Self.log(diagnosticPayloads: payloads)
        }
    }

    /// New metrics, about daily, with the exit counts.
    func didReceive(_ payloads: [MXMetricPayload]) {
        queue.async {
            Self.log(metricPayloads: payloads)
        }
    }

    // MARK: to the sdk

    /// Each payload's json and times to the sdk, which writes the lines and
    /// skips one it has logged. On `queue`.
    private static func log(diagnosticPayloads: [MXDiagnosticPayload]) {
        for payload in diagnosticPayloads {
            guard let payloadJson = String(data: payload.jsonRepresentation(), encoding: .utf8) else {
                continue
            }
            SdkLogMetricKitDiagnosticPayload(
                payloadJson,
                unixMillis(payload.timeStampBegin),
                unixMillis(payload.timeStampEnd)
            )
        }
    }

    /// As the diagnostic payloads; the sdk writes their exit counts.
    private static func log(metricPayloads: [MXMetricPayload]) {
        for payload in metricPayloads {
            guard let payloadJson = String(data: payload.jsonRepresentation(), encoding: .utf8) else {
                continue
            }
            SdkLogMetricKitMetricPayload(
                payloadJson,
                unixMillis(payload.timeStampBegin),
                unixMillis(payload.timeStampEnd)
            )
        }
    }

    /// A payload's time in unix milliseconds, or 0 when it is not one the sdk
    /// can take, which then reads the payload json's own.
    static func unixMillis(_ date: Date) -> Int64 {
        let millis = (date.timeIntervalSince1970 * 1000).rounded()
        guard millis.isFinite, 0 < millis, millis < Double(Int64.max) else {
            return 0
        }
        return Int64(millis)
    }
}

#endif
