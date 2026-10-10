//
//  SessionsStore.swift
//  URnetwork
//
//  Account > Sessions (server/session/REVOKE-UI-FINAL.md): the account's
//  signed-in sessions and their sign-out, from the SDK's shared
//  ClientSessionViewController. The controller owns everything about the
//  sessions themselves: fetching, the account credential, polling every 30 s
//  while visible, retries, operation ids, pending (202) recovery, and the
//  sign-out of this app once its own session is revoked (it rejects the
//  account credential, so the app's logout listeners take over). This store
//  only mirrors the controller's snapshots into value types, forwards the
//  screen's lifecycle and intents, and holds the confirmation a sign-out
//  waits for.
//
//  Everything here runs on the main actor; the controller's listener fires on
//  an SDK thread and hops to the main queue before it touches the store.
//

import Foundation
import URnetworkSdk

// MARK: Snapshot

/// The server's last observed authenticated use of a session.
struct SessionLastUsedItem: Equatable {
    /// UTC Unix seconds
    var unixTime: Int64
    // GeoLite2 names; empty when unknown
    var city: String = ""
    var region: String = ""
    var country: String = ""
    /// lower-case ISO alpha-2, or empty
    var countryCode: String = ""
    /// android, ios, macos, windows, linux, web, cli, server or unknown
    var deviceType: String = "unknown"
    /// the version reported with that use; empty when unknown
    var appVersion: String = ""
}

/// One signed-in session.
struct SessionItem: Equatable, Identifiable {
    /// the full session id
    let id: String
    /// the session this app is signed in with
    var current: Bool = false
    /// how it signed in: password, google, ..., or a legacy kind
    var kind: String = ""
    /// unix milliseconds; nil when the server sent none
    var createTimeMillis: Int64? = nil
    /// nil when no use was observed
    var lastUsed: SessionLastUsedItem? = nil
}

/// A failed request, by its flags. The SDK's message is never shown.
struct SessionErrorItem: Equatable {
    var retryable: Bool = false
    var signInRequired: Bool = false
    var unsupported: Bool = false
}

/// A sign-out the controller is running or has finished with an error: one
/// session's, or the bulk sign-out of the other sessions.
struct SessionActionItem: Equatable {
    /// the signed-out session; nil for the bulk action
    var sessionId: String? = nil
    /// the request is in flight
    var loading: Bool = false
    /// accepted (202) and not yet confirmed enforced
    var pending: Bool = false
    var error: SessionErrorItem? = nil

    /// the row shows "Signing out…" and its control is disabled
    var inProgress: Bool {
        loading || pending
    }
}

/// What the screen shows in place of the list, or the list itself.
enum SessionsContent: Equatable {
    /// never loaded
    case loading
    /// the first load failed
    case loadFailed
    /// the server does not support sessions yet
    case unsupported
    /// loaded with no sessions
    case empty
    case list
}

/// One read of the controller, in its display order.
struct SessionsSnapshot: Equatable {
    /// current first, then the most recent known use
    var sessions: [SessionItem] = []
    var currentSessionId: String? = nil
    /// "partial" while sign-ins from older app versions may be missing
    var legacyCoverage: String = ""
    var loaded: Bool = false
    var loading: Bool = false
    var refreshing: Bool = false
    var supported: Bool = true
    var bulkAction: SessionActionItem? = nil
    var actions: [SessionActionItem] = []
    var error: SessionErrorItem? = nil

    var content: SessionsContent {
        if !supported || error?.unsupported == true {
            return .unsupported
        }
        if !loaded {
            // a retry after a failed first load shows progress again
            return error != nil && !loading ? .loadFailed : .loading
        }
        return sessions.isEmpty ? .empty : .list
    }

    /// A refresh failed after a list was loaded: the list stays, with a
    /// non-blocking notice.
    var refreshFailed: Bool {
        loaded && error != nil && content != .unsupported
    }

    func isCurrent(_ session: SessionItem) -> Bool {
        session.current || (currentSessionId != nil && session.id == currentSessionId)
    }

    /// Only with this app's session and at least one other.
    var showsSignOutOthers: Bool {
        sessions.contains { isCurrent($0) } && sessions.contains { !isCurrent($0) }
    }

    var signingOutOthers: Bool {
        bulkAction?.inProgress ?? false
    }

    /// Older sign-ins appear once they renew.
    var legacyCoveragePartial: Bool {
        legacyCoverage == "partial"
    }

    func action(for sessionId: String) -> SessionActionItem? {
        actions.first { $0.sessionId == sessionId }
    }
}

/// A sign-out waiting for the user's confirmation.
enum SessionsConfirmation: Equatable {
    /// one session; `place` is empty when unknown, and `current` is this
    /// app's own session
    case signOut(sessionId: String, device: String, place: String, current: Bool)
    case signOutOthers
}

// MARK: Controller

/// The SDK controller as the store drives it. A protocol so the tests stand in
/// for the SDK.
protocol ClientSessionControlling: AnyObject {
    /// Subscribes to the api's session changes and loads.
    func start()
    /// Polls every 30 s while visible; becoming visible refreshes.
    func setVisible(_ visible: Bool)
    /// Coming to the foreground refreshes.
    func setForeground(_ foreground: Bool)
    func refresh()
    /// Signs one session out. A repeat while it is in progress is ignored and
    /// a retry reuses its operation.
    func revokeSession(_ sessionId: String)
    func revokeOtherSessions()
    /// Calls `changed` on an SDK thread after every snapshot, until the
    /// subscription is closed.
    func addSnapshotListener(_ changed: @escaping @Sendable () -> Void) -> SdkSubProtocol?
    /// The controller's newest snapshot (empty for a replaced credential).
    func readSnapshot() -> SessionsSnapshot
    /// Ends the controller; a request still in flight changes nothing after.
    func close()
}

/// What opens the controller: the account api.
protocol ClientSessionControllerOwner: AnyObject {
    func openClientSessionController() -> ClientSessionControlling?
}

/**
 * Publishes the account's sessions for Account > Sessions.
 *
 * Lifecycle (REVOKE-UI-FINAL.md §6): the controller opens and starts the first
 * time the screen is visible, polls only while it is (on screen and the app
 * presenting, the lifecycle the rest of the app uses, so a backgrounded app or
 * a hidden macOS window stops it), and hears the app's foreground changes.
 * `close` (and deinit, when the screen goes) drops the listener first, then
 * closes the controller; nothing it reports afterwards lands.
 *
 * Every hop of the listener reads the controller's newest snapshot rather
 * than the one it was handed, so a snapshot delivered late on another SDK
 * thread never replaces a newer one.
 */
@MainActor
final class SessionsStore: ObservableObject {

    @Published private(set) var snapshot = SessionsSnapshot()
    /// the sign-out waiting for the user's answer
    @Published private(set) var confirmation: SessionsConfirmation? = nil

    /// Runs `work` on the main actor later. Tests pass a queue they drain.
    typealias Dispatch = (@escaping @MainActor () -> Void) -> Void

    nonisolated static func dispatchOnMainQueue(_ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                work()
            }
        }
    }

    private let owner: ClientSessionControllerOwner
    private let dispatch: Dispatch
    private var controller: ClientSessionControlling?
    private var listenerSub: SdkSubProtocol?
    private var closed = false

    private var onScreen = false
    private var presentationActive = false
    // what the controller was last told
    private var visible = false

    // pull to refresh waits for a refresh the controller finishes after the
    // request; notifications are numbered as they are posted to tell those
    // from ones already queued
    private let notifications = SessionsNotificationSequence()
    private var refreshWaiters: [(after: UInt64, continuation: CheckedContinuation<Void, Never>)] = []

    init(owner: ClientSessionControllerOwner, dispatch: @escaping Dispatch = SessionsStore.dispatchOnMainQueue) {
        self.owner = owner
        self.dispatch = dispatch
    }

    deinit {
        // the screen is gone: listener first, then the controller
        listenerSub?.close()
        controller?.close()
    }

    // MARK: Lifecycle

    /// The screen appeared or disappeared.
    func setOnScreen(_ onScreen: Bool) {
        self.onScreen = onScreen
        updateVisible()
    }

    /// The app started or stopped presenting (scene active, window visible).
    func setPresentationActive(_ active: Bool) {
        guard presentationActive != active else {
            return
        }
        presentationActive = active
        controller?.setForeground(active)
        updateVisible()
    }

    /// Drops the listener, then closes the controller. Final.
    func close() {
        guard !closed else {
            return
        }
        closed = true
        listenerSub?.close()
        listenerSub = nil
        controller?.close()
        controller = nil
        visible = false
        confirmation = nil
        let waiters = refreshWaiters
        refreshWaiters = []
        for waiter in waiters {
            waiter.continuation.resume()
        }
    }

    private func updateVisible() {
        let nextVisible = !closed && onScreen && presentationActive
        guard nextVisible != visible else {
            return
        }
        visible = nextVisible
        if nextVisible {
            openController()
        }
        controller?.setVisible(nextVisible)
    }

    /// Opens, subscribes to and starts the controller the first time.
    private func openController() {
        guard controller == nil, !closed, let controller = owner.openClientSessionController() else {
            return
        }
        self.controller = controller
        let notifications = self.notifications
        let dispatch = self.dispatch
        listenerSub = controller.addSnapshotListener { [weak self] in
            let notification = notifications.next()
            dispatch {
                self?.update(notification: notification)
            }
        }
        controller.start()
        update(notification: nil)
    }

    /// Reads the controller's newest snapshot.
    private func update(notification: UInt64?) {
        guard !closed, let controller else {
            return
        }
        let next = controller.readSnapshot()
        if next != snapshot {
            snapshot = next
        }
        if let notification, !snapshot.refreshing, !snapshot.loading {
            let finished = refreshWaiters.filter { $0.after < notification }
            refreshWaiters.removeAll { $0.after < notification }
            for waiter in finished {
                waiter.continuation.resume()
            }
        }
    }

    // MARK: Intents

    /// The toolbar refresh, Try again, or a pull.
    func refresh() {
        guard !closed else {
            return
        }
        controller?.refresh()
    }

    /**
     * Refreshes, then returns once the controller has finished a refresh
     * after this request, so the pull indicator shows the snapshot's
     * refreshing. Returns at once without a controller, and when the store
     * closes.
     */
    func refreshAndWait() async {
        guard !closed, let controller else {
            return
        }
        let after = notifications.current
        controller.refresh()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            refreshWaiters.append((after: after, continuation: continuation))
        }
    }

    /**
     * A row's sign-out: asks first. Nothing happens for a session that is
     * already signing out (a repeated activation), or one no longer listed.
     */
    func requestSignOut(sessionId: String) {
        guard !closed,
              let session = snapshot.sessions.first(where: { $0.id == sessionId }),
              !(snapshot.action(for: sessionId)?.inProgress ?? false) else {
            return
        }
        confirmation = .signOut(
            sessionId: sessionId,
            device: SessionLabels.device(session.lastUsed?.deviceType ?? "").label,
            place: SessionLabels.place(session.lastUsed),
            current: snapshot.isCurrent(session)
        )
    }

    /// The bulk sign-out: asks first, and only while it is offered.
    func requestSignOutOthers() {
        guard !closed, snapshot.showsSignOutOthers, !snapshot.signingOutOthers else {
            return
        }
        confirmation = .signOutOthers
    }

    /**
     * The user confirmed `confirmation` (the dialog hands back the one it
     * presented). The controller shows the action at once.
     */
    func confirm(_ confirmation: SessionsConfirmation) {
        self.confirmation = nil
        guard !closed, let controller else {
            return
        }
        switch confirmation {
        case .signOut(let sessionId, _, _, _):
            controller.revokeSession(sessionId)
        case .signOutOthers:
            controller.revokeOtherSessions()
        }
        update(notification: nil)
    }

    /// Cancel, the default: nothing is signed out.
    func cancelConfirmation() {
        confirmation = nil
    }
}

/// Numbers the controller's notifications as they are posted, on SDK threads.
private final class SessionsNotificationSequence: @unchecked Sendable {
    private let stateLock = NSLock()
    private var value: UInt64 = 0

    func next() -> UInt64 {
        stateLock.lock()
        defer { stateLock.unlock() }
        value += 1
        return value
    }

    var current: UInt64 {
        stateLock.lock()
        defer { stateLock.unlock() }
        return value
    }
}

// MARK: SDK

/// The SDK's session listener, calling a closure. The snapshot it is handed
/// is not used: the store reads the newest one on the main queue.
private class ClientSessionListener: NSObject, SdkClientSessionListenerProtocol {
    private let callback: @Sendable () -> Void

    init(_ callback: @escaping @Sendable () -> Void) {
        self.callback = callback
    }

    func clientSessionsChanged(_ snapshot: SdkClientSessionSnapshot?) {
        callback()
    }
}

extension SdkClientSessionViewController: ClientSessionControlling {

    func revokeSession(_ sessionId: String) {
        var parseError: NSError?
        guard let id = SdkParseId(sessionId, &parseError), parseError == nil else {
            return
        }
        revokeSession(id)
    }

    func addSnapshotListener(_ changed: @escaping @Sendable () -> Void) -> SdkSubProtocol? {
        add(ClientSessionListener(changed))
    }

    func readSnapshot() -> SessionsSnapshot {
        SessionsSnapshot(getSnapshot())
    }
}

extension SdkApi: ClientSessionControllerOwner {

    /// The api-only controller (Api.OpenClientSessionViewController): the api
    /// owns its credential and cancellation, so no device is needed.
    func openClientSessionController() -> ClientSessionControlling? {
        openClientSessionViewController()
    }
}

extension SessionsSnapshot {

    /// A copy of the SDK's snapshot.
    init(_ snapshot: SdkClientSessionSnapshot?) {
        self.init()
        guard let snapshot else {
            return
        }
        if let list = snapshot.sessions {
            sessions.reserveCapacity(list.len())
            for i in 0..<list.len() {
                if let info = list.get(i), let session = SessionItem(info) {
                    sessions.append(session)
                }
            }
        }
        currentSessionId = snapshot.currentSessionId?.idStr
        legacyCoverage = snapshot.legacyCoverage
        loaded = snapshot.loaded
        loading = snapshot.loading
        refreshing = snapshot.refreshing
        supported = snapshot.supported
        bulkAction = snapshot.bulkAction.map { SessionActionItem($0) }
        if let list = snapshot.actions {
            for i in 0..<list.len() {
                if let action = list.get(i) {
                    actions.append(SessionActionItem(action))
                }
            }
        }
        error = snapshot.error.map { SessionErrorItem($0) }
    }
}

extension SessionItem {

    /// A copy of the SDK's session; nil without a session id.
    init?(_ info: SdkNetworkSessionInfo) {
        guard let sessionId = info.sessionId?.idStr, !sessionId.isEmpty else {
            return nil
        }
        self.init(
            id: sessionId,
            current: info.current,
            kind: info.kind,
            createTimeMillis: info.createTime?.unixMilli(),
            lastUsed: info.lastUsed.map { lastUsed in
                SessionLastUsedItem(
                    unixTime: lastUsed.unixTime,
                    city: lastUsed.city,
                    region: lastUsed.region,
                    country: lastUsed.country,
                    countryCode: lastUsed.countryCode,
                    deviceType: lastUsed.deviceType,
                    appVersion: lastUsed.appVersion
                )
            }
        )
    }
}

extension SessionActionItem {

    init(_ action: SdkClientSessionAction) {
        self.init(
            sessionId: action.sessionId?.idStr,
            loading: action.loading,
            pending: action.pending,
            error: action.error.map { SessionErrorItem($0) }
        )
    }
}

extension SessionErrorItem {

    init(_ error: SdkClientSessionError) {
        self.init(
            retryable: error.retryable,
            signInRequired: error.signInRequired,
            unsupported: error.unsupported
        )
    }
}
