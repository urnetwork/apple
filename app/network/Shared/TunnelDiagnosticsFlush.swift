//
//  TunnelDiagnosticsFlush.swift
//  URnetwork
//
//  Asks the running packet tunnel extension to flush its glog buffers before
//  the app reads its log files for a diagnostic export.
//
//  The zip is assembled in the app process, and FlushGlog only flushes the
//  glog of the process that calls it. The extension buffers each severity file
//  through a 256KiB writer and flushes on a 30 second ticker, so without this
//  a bundle routinely stops up to 30 seconds short of the failure the user is
//  reporting -- the one window the export exists to capture.
//
//  Best effort by construction: an export must never fail, or hang, because
//  the tunnel did not answer.
//

import Foundation
import NetworkExtension

enum TunnelDiagnosticsFlush {

    static let providerMessage = Data("flush-logs".utf8)

    /// Resumes exactly once, whichever of the reply and the timeout lands
    /// first.
    private final class OneShot: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?

        init(_ continuation: CheckedContinuation<Void, Never>) {
            self.continuation = continuation
        }

        func resume() {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume()
        }
    }

    /// Returns when the extension has flushed, or when `timeout` elapses,
    /// or immediately when no tunnel session is running (nothing to flush).
    static func requestExtensionFlush(timeout: TimeInterval = 2) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = OneShot(continuation)

            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                once.resume()
            }

            NETunnelProviderManager.loadAllFromPreferences { managers, _ in
                let session = (managers ?? [])
                    .compactMap { $0.connection as? NETunnelProviderSession }
                    .first { session in
                        switch session.status {
                        case .connected, .connecting, .reasserting:
                            return true
                        default:
                            return false
                        }
                    }

                guard let session else {
                    once.resume()
                    return
                }

                do {
                    try session.sendProviderMessage(providerMessage) { _ in
                        once.resume()
                    }
                } catch {
                    once.resume()
                }
            }
        }
    }
}
