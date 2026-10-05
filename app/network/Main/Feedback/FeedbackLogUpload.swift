//
//  FeedbackLogUpload.swift
//  URnetwork
//
//  "Send feedback with logs": which process uploads the log files.
//
//  The upload is one zip of the glog files under the log root the app and the
//  packet tunnel extension share (Logs/app and Logs/extension in the App Group
//  container), posted to /log/{feedback_id}/upload, which the server rate
//  limits to one upload per network per 5 minutes. Either process can build it
//  (the sdk's UploadLogs), and either one's zip holds both processes' logs:
//
//  - While the device rpc reaches the extension, the extension uploads. Its
//    sockets stay outside the tunnel, so a tunnel that is connected but carries
//    no traffic does not keep its logs from leaving. The sdk flushes the app's
//    glog before it asks, so the app's newest lines are in the extension's zip.
//  - When the rpc cannot carry the request (the tunnel is down, or the rpc has
//    not connected) the app uploads the same files through its own api. It
//    first asks a running tunnel to flush its glog, and the direct-download
//    build mirrors the system extension's logs into the app's root, the only
//    place the app can read them from.
//
//  The app uploads only when the extension could not be asked, so a feedback
//  gets one upload and the rate limit is never spent twice. Asking only the
//  extension, as the app did, uploaded nothing while the tunnel was down, and
//  never the app's own logs.
//
//  The direct-download build's system extension logs to /Library/Logs, which
//  holds no app logs, so with the tunnel up that build's upload holds the
//  extension's logs only.
//

import Foundation
import URnetworkSdk

enum FeedbackLogUpload {

    /// The process that took the upload, or why neither did.
    enum Outcome: Equatable {
        /// the extension took the request over the device rpc
        case extensionProcess
        /// the app process is uploading through its own api
        case appProcess
        /// neither process could start the upload
        case failed(String)
    }

    /// What an upload needs from the two processes. The real ones are `live`;
    /// tests pass their own to check the order.
    struct Steps {
        /// Asks the extension over the device rpc, and throws when the rpc
        /// cannot carry the request. nil without a device.
        var uploadThroughExtension: ((String) throws -> Void)?
        /// Asks a running tunnel to flush its glog, and returns at once when no
        /// tunnel runs.
        var requestExtensionFlush: () async -> Void
        /// Brings the logs the app cannot read in place into its log root: the
        /// direct-download build's mirror of the system extension's logs.
        var prepareAppLogRoot: () -> Void
        /// Uploads from this process through its api, and throws when the zip
        /// cannot be built. nil without an api.
        var uploadFromApp: ((String) throws -> Void)?
    }

    /// Starts the upload in one process: the extension when the rpc can ask
    /// it, else the app. Both read the log files from disk before they return,
    /// so call this off the main actor.
    static func upload(feedbackId: String, steps: Steps) async -> Outcome {
        var extensionError: String?
        if let uploadThroughExtension = steps.uploadThroughExtension {
            do {
                try uploadThroughExtension(feedbackId)
                return .extensionProcess
            } catch {
                extensionError = error.localizedDescription
            }
        }

        guard let uploadFromApp = steps.uploadFromApp else {
            return .failed(failureReason(extensionError: extensionError, appError: "no api"))
        }
        // the newest extension lines are still in a running tunnel's memory,
        // and the system extension's logs are not in the app's root at all
        await steps.requestExtensionFlush()
        steps.prepareAppLogRoot()
        do {
            try uploadFromApp(feedbackId)
            return .appProcess
        } catch {
            return .failed(failureReason(extensionError: extensionError, appError: error.localizedDescription))
        }
    }

    /// Why neither process took the upload, for the log.
    static func failureReason(extensionError: String?, appError: String) -> String {
        "extension: \(extensionError ?? "no device"); app: \(appError)"
    }
}

extension FeedbackLogUpload.Steps {

    /// The steps against the app's device and api.
    static func live(device: SdkDeviceRemote?, api: SdkApi?) -> Self {
        Self(
            uploadThroughExtension: device.map { device in
                { feedbackId in
                    try device.uploadLogs(feedbackId, callback: nil)
                }
            },
            requestExtensionFlush: {
                await TunnelDiagnosticsFlush.requestExtensionFlush()
            },
            prepareAppLogRoot: {
                #if os(macOS) && DIRECT_DOWNLOAD
                SystemExtensionLogMirror.sync()
                #endif
            },
            uploadFromApp: api.map { api in
                { feedbackId in
                    try api.uploadLogs(feedbackId, callback: FeedbackLogUploadResult())
                }
            }
        )
    }
}

/// Logs how the app's own upload ended: the server answers a refusal (the rate
/// limit, the size cap) in the result rather than as an error.
private class FeedbackLogUploadResult: NSObject, SdkUploadLogsCallbackProtocol {

    func result(_ result: SdkUploadLogsResult?, err: Error?) {
        if let err {
            print("[FeedbackLogUpload]app upload failed: \(err.localizedDescription)")
        } else if let message = result?.error?.message {
            print("[FeedbackLogUpload]app upload refused: \(message)")
        } else {
            print("[FeedbackLogUpload]app upload done")
        }
    }
}
