//
//  NetworkNameCheck.swift
//  URnetwork
//
//  The online network name availability check on the create network form,
//  ported from android ui/login/NetworkNameCheck.kt (the Windows and Linux
//  apps carry the same flow).
//
//  Kept free of SwiftUI and of the SDK so it can be tested directly: the
//  online check and the timers are injected.
//

import Foundation

/// The state of the network name availability check.
///
/// A check that errored or never answered (offline, timeout, server error) is
/// `failed`, not `unavailable`: the name was never judged. A failed name may
/// still be submitted, because network create re-checks availability on the
/// server and rejects a taken name with its own error.
enum NetworkNameCheckState: Equatable {
    case empty
    case tooShort
    case checking
    case available
    case unavailable
    case failed

    /// the name may be submitted to network create
    var allowsCreate: Bool {
        self == .available || self == .failed
    }
}

/// Runs the availability check for the latest name the user entered.
///
/// `check` starts one online check and answers `true`/`false` for
/// available/unavailable, or `nil` when the check errored. `schedule` runs an
/// action after a delay and returns a function that cancels it. A name is
/// checked once it has been left unedited for `debounceDelay`, and only the
/// answer for the latest attempt is applied. A failed check is retried
/// automatically a bounded number of times, and a check that never answers
/// fails after `checkTimeout`.
///
/// Not safe for concurrent use: call it, and deliver `check` answers and
/// scheduled actions, on one thread.
final class NetworkNameCheck {

    typealias Check = (_ networkName: String, _ onResult: @escaping (_ available: Bool?) -> Void) -> Void
    typealias Schedule = (_ delay: TimeInterval, _ action: @escaping () -> Void) -> () -> Void

    static let minLength = 6

    /// a name is checked once it has been left unedited this long
    static let debounceDelay: TimeInterval = 0.25

    /// automatic re-checks of the same name after a failed check
    static let maxRetryCount = 3
    static let retryDelay: TimeInterval = 3

    /// a check with no answer by then is treated as failed
    static let checkTimeout: TimeInterval = 15

    /// `available` is nil when the check errored or returned no result
    static func resultState(_ available: Bool?) -> NetworkNameCheckState {
        switch available {
        case .some(true):
            return .available
        case .some(false):
            return .unavailable
        case .none:
            return .failed
        }
    }

    private(set) var state: NetworkNameCheckState = .empty

    private let check: Check
    private let schedule: Schedule
    private let onStateChange: (NetworkNameCheckState) -> Void

    private var networkName = ""
    private var attempt = 0
    private var retryCount = 0
    private var cancelScheduled: (() -> Void)?

    init(
        check: @escaping Check,
        schedule: @escaping Schedule,
        onStateChange: @escaping (NetworkNameCheckState) -> Void = { _ in }
    ) {
        self.check = check
        self.schedule = schedule
        self.onStateChange = onStateChange
    }

    /// The name was edited: drops the check in flight and any pending retry,
    /// and checks the new name after the debounce.
    func validate(_ networkName: String) {
        self.networkName = networkName
        retryCount = 0
        attempt += 1
        cancelPending()

        if let localState = localState() {
            setState(localState)
            return
        }

        setState(.checking)
        let debounceAttempt = attempt
        cancelScheduled = schedule(Self.debounceDelay) { [weak self] in
            guard let self, debounceAttempt == self.attempt else {
                return
            }
            self.start()
        }
    }

    private func localState() -> NetworkNameCheckState? {
        if networkName.isEmpty {
            return .empty
        }
        if networkName.count < Self.minLength {
            return .tooShort
        }
        return nil
    }

    /// Runs one online check. Only the first check after an edit shows
    /// `checking`; a retry keeps showing `failed`, so Create stays usable
    /// while it runs, as in the Windows and Linux apps.
    private func start() {
        attempt += 1
        cancelPending()

        let checkAttempt = attempt
        cancelScheduled = schedule(Self.checkTimeout) { [weak self] in
            guard let self, checkAttempt == self.attempt else {
                return
            }
            self.finish(nil)
        }
        check(networkName) { [weak self] available in
            guard let self, checkAttempt == self.attempt else {
                return
            }
            self.finish(available)
        }
    }

    private func finish(_ available: Bool?) {
        // a late answer for this attempt is ignored
        attempt += 1
        cancelPending()

        let nextState = Self.resultState(available)
        setState(nextState)

        if nextState == .failed && retryCount < Self.maxRetryCount {
            retryCount += 1
            let retryAttempt = attempt
            cancelScheduled = schedule(Self.retryDelay) { [weak self] in
                guard let self, retryAttempt == self.attempt else {
                    return
                }
                self.start()
            }
        }
    }

    private func cancelPending() {
        cancelScheduled?()
        cancelScheduled = nil
    }

    private func setState(_ nextState: NetworkNameCheckState) {
        if state != nextState {
            state = nextState
            onStateChange(nextState)
        }
    }
}
