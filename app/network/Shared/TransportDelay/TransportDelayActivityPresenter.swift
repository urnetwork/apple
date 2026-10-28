//
//  TransportDelayActivityPresenter.swift
//  URnetwork
//
//  The ActivityKit calls behind the slow internet Live Activity, for the
//  process that drives it (apple/DELAY.md §5.5): the packet tunnel extension
//  from its own transport delay listener, and the app while it is in the
//  foreground. Which of them iOS lets start, update and end an activity is
//  what spike S1 measures on a phone, so every call's outcome and every
//  ActivityKit error goes to the driver's log.
//
//  Whoever drives, there is one activity: a show updates the one already up,
//  whichever process started it (the app re-attaches through
//  Activity.activities), and ends any duplicate a race made.
//
//  Compiled into the app and the packet tunnel extension. iOS only:
//  ActivityKit is unavailable on macOS.
//

#if os(iOS)
import ActivityKit
import Foundation

@available(iOS 16.2, *)
final class TransportDelayActivityPresenter {
    typealias LiveActivity = Activity<TransportDelayAttributes>
    typealias ContentState = TransportDelayAttributes.ContentState

    enum ShowOutcome: Equatable {
        /// An activity was up and now shows the content.
        case updated
        /// None was up and one started.
        case started
        /// None was up and the request failed (logged).
        case startFailed
        /// None was up and none was asked for: not allowed now, or the
        /// content is the recovered state, which never starts an activity.
        case notStarted
    }

    /// Whether the user allows this app's Live Activities (Settings).
    static var activitiesEnabled: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    /// One line per call outcome and per error, for the driver's log.
    private let log: (String) -> Void
    private let stateLock = NSLock()
    // the async updates and ends, run one after another in the order made
    private var tail: Task<Void, Never>?

    init(log: @escaping (String) -> Void) {
        self.log = log
    }

    /// This app's slow internet activities that are still up, the oldest the
    /// system lists first.
    static func liveActivities() -> [LiveActivity] {
        LiveActivity.activities.filter { activity in
            switch activity.activityState {
            case .active, .stale:
                return true
            default:
                return false
            }
        }
    }

    static var isUp: Bool {
        !liveActivities().isEmpty
    }

    /// Shows `content`, stale at `staleDate`: updates the activity that is up,
    /// or, with none up and `allowStart`, starts one silently. `transient`
    /// asks for the transient style (iOS 18), the spike's other variant.
    @discardableResult
    func show(_ content: ContentState, staleDate: Date, allowStart: Bool, transient: Bool = false) -> ShowOutcome {
        let activities = Self.liveActivities()
        if let activity = activities.first {
            let duplicates = Array(activities.dropFirst())
            if !duplicates.isEmpty {
                log("ending \(duplicates.count) duplicate activities")
            }
            let update = ActivityContent(state: content, staleDate: staleDate)
            enqueue {
                await activity.update(update)
                for duplicate in duplicates {
                    await duplicate.end(nil, dismissalPolicy: .immediate)
                }
            }
            return .updated
        }
        guard allowStart, !content.recovered else {
            return .notStarted
        }
        let enabled = Self.activitiesEnabled
        do {
            let request = ActivityContent(state: content, staleDate: staleDate)
            if transient, #available(iOS 18.0, *) {
                _ = try LiveActivity.request(
                    attributes: TransportDelayAttributes(),
                    content: request,
                    pushType: nil,
                    style: .transient
                )
            } else {
                _ = try LiveActivity.request(
                    attributes: TransportDelayAttributes(),
                    content: request,
                    pushType: nil
                )
            }
            log("start ok level=\(content.level) style=\(transient ? "transient" : "standard") enabled=\(enabled)")
            return .started
        } catch let error as ActivityAuthorizationError {
            log("start failed ActivityAuthorizationError.\(error) reason=\(error.failureReason ?? "none") enabled=\(enabled)")
        } catch {
            log("start failed \(type(of: error)) code=\((error as NSError).code) enabled=\(enabled)")
        }
        return .startFailed
    }

    /// Ends every activity at once, after the updates made so far. `content`
    /// is what an activity that lingers on the Lock Screen keeps.
    func endAll(_ content: ContentState? = nil) {
        let activities = Self.liveActivities()
        guard !activities.isEmpty else {
            return
        }
        log("end count=\(activities.count)")
        let final = content.map { ActivityContent(state: $0, staleDate: nil) }
        enqueue {
            for activity in activities {
                await activity.end(final, dismissalPolicy: .immediate)
            }
        }
    }

    /// Waits up to `timeout` for the updates and ends made so far, for a
    /// process about to exit. Returns whether they finished.
    @discardableResult
    func waitForPending(timeout: TimeInterval) -> Bool {
        let pending = stateLock.withLock { tail }
        guard let pending else {
            return true
        }
        let done = DispatchSemaphore(value: 0)
        Task {
            await pending.value
            done.signal()
        }
        return done.wait(timeout: .now() + timeout) == .success
    }

    private func enqueue(_ operation: @escaping () async -> Void) {
        stateLock.withLock {
            let previous = tail
            tail = Task {
                await previous?.value
                await operation()
            }
        }
    }
}
#endif
