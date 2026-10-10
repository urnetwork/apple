//
//  SessionsStoreTests.swift
//  networkTests
//

import Foundation
import Testing
import URnetworkSdk
@testable import URnetwork

/**
 * Account > Sessions' store over a fake controller (REVOKE-UI-FINAL.md §4,
 * §6, §10): the lifecycle it forwards, the confirmation every sign-out waits
 * for, the pending and failed states the controller reports, and that nothing
 * lands after the screen is gone. The listener's main-queue hops go to a
 * queue each test drains itself, so nothing waits, polls or reads a clock.
 */
@MainActor
struct SessionsStoreTests {

    // test-only session ids
    private static let thisSession = "01a1f3c2-0000-4000-8000-00000000000a"
    private static let otherSession = "02b2e4d3-0000-4000-8000-00000000000b"
    private static let thirdSession = "03c3d5e4-0000-4000-8000-00000000000c"

    private final class Events {
        var log: [String] = []
    }

    private final class FakeSub: NSObject, SdkSubProtocol {
        private let onClose: () -> Void

        init(_ onClose: @escaping () -> Void) {
            self.onClose = onClose
        }

        func close() {
            onClose()
        }
    }

    private final class FakeController: ClientSessionControlling {
        private let events: Events
        var snapshot = SessionsSnapshot()
        var listener: (@Sendable () -> Void)?
        /// runs inside refresh(), as the SDK's refresh would post
        var onRefresh: (() -> Void)?
        /// runs inside a revoke (nil for the bulk one), before it returns
        var onRevoke: ((String?) -> Void)?

        init(_ events: Events) {
            self.events = events
        }

        func start() {
            events.log.append("start")
        }

        func setVisible(_ visible: Bool) {
            events.log.append("visible \(visible)")
        }

        func setForeground(_ foreground: Bool) {
            events.log.append("foreground \(foreground)")
        }

        func refresh() {
            events.log.append("refresh")
            onRefresh?()
        }

        func revokeSession(_ sessionId: String) {
            events.log.append("revoke \(sessionId)")
            onRevoke?(sessionId)
        }

        func revokeOtherSessions() {
            events.log.append("revoke others")
            onRevoke?(nil)
        }

        func addSnapshotListener(_ changed: @escaping @Sendable () -> Void) -> SdkSubProtocol? {
            listener = changed
            events.log.append("listen")
            return FakeSub { [events] in
                events.log.append("unlisten")
            }
        }

        func readSnapshot() -> SessionsSnapshot {
            snapshot
        }

        func close() {
            events.log.append("close")
        }

        /// The controller changing to `next` and notifying, as the SDK does
        /// from its own thread.
        func publish(_ next: SessionsSnapshot) {
            snapshot = next
            listener?()
        }
    }

    private final class FakeOwner: ClientSessionControllerOwner {
        private let events: Events
        var opened: [FakeController] = []

        init(_ events: Events) {
            self.events = events
        }

        func openClientSessionController() -> ClientSessionControlling? {
            let controller = FakeController(events)
            opened.append(controller)
            events.log.append("open")
            return controller
        }
    }

    /// Set when a pull's refresh returns.
    private final class Flag {
        var value = false
    }

    /// The listener's hops to the main queue, run when the test says.
    private final class Hops {
        var pending: [@MainActor () -> Void] = []

        func dispatch(_ work: @escaping @MainActor () -> Void) {
            pending.append(work)
        }

        @MainActor
        func run() {
            let work = pending
            pending = []
            for hop in work {
                hop()
            }
        }
    }

    private func makeStore(_ events: Events = Events(), hops: Hops = Hops()) -> (SessionsStore, FakeOwner, Hops) {
        let owner = FakeOwner(events)
        let store = SessionsStore(owner: owner, dispatch: hops.dispatch)
        return (store, owner, hops)
    }

    /// On screen with the app presenting: the controller is open.
    private func showing(_ events: Events = Events()) throws -> (SessionsStore, FakeController, Hops, Events) {
        let (store, owner, hops) = makeStore(events)
        store.setPresentationActive(true)
        store.setOnScreen(true)
        let controller = try #require(owner.opened.first)
        return (store, controller, hops, events)
    }

    private static func session(
        _ id: String,
        current: Bool = false,
        deviceType: String = "android",
        city: String = "Springfield",
        region: String = "Illinois",
        country: String = "United States"
    ) -> SessionItem {
        SessionItem(
            id: id,
            current: current,
            kind: "google",
            createTimeMillis: 1_790_000_000_000,
            lastUsed: SessionLastUsedItem(
                unixTime: 1_790_900_000,
                city: city,
                region: region,
                country: country,
                countryCode: "us",
                deviceType: deviceType,
                appVersion: "2026.10.8-1067"
            )
        )
    }

    private static func loaded(_ sessions: [SessionItem]) -> SessionsSnapshot {
        var snapshot = SessionsSnapshot()
        snapshot.sessions = sessions
        snapshot.currentSessionId = sessions.first(where: \.current)?.id
        snapshot.legacyCoverage = "partial"
        snapshot.loaded = true
        return snapshot
    }

    private static var twoSessions: SessionsSnapshot {
        loaded([session(thisSession, current: true, deviceType: "ios"), session(otherSession)])
    }

    /// Runs what is queued on the main queue so far: a hop, or a task's next
    /// step.
    private func drainMainQueue() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }

    // MARK: Lifecycle

    // on screen while the app is in the background, or the app presenting
    // with the screen not shown: nothing is opened
    @Test func nothingOpensUntilTheScreenShowsWhileTheAppPresents() {
        let events = Events()
        let (store, owner, _) = makeStore(events)
        store.setOnScreen(true)
        #expect(owner.opened.isEmpty)
        store.setOnScreen(false)
        store.setPresentationActive(true)
        #expect(owner.opened.isEmpty)
        #expect(events.log.isEmpty)
    }

    // §6: on appear, Start() and SetVisible(true)
    @Test func appearingOpensListensStartsAndShows() throws {
        let (store, _, _, events) = try showing()
        withExtendedLifetime(store) {
            #expect(events.log == ["open", "listen", "start", "visible true"])
        }
    }

    // the screen going away releases its store: the same teardown as close,
    // listener first
    @Test func disposingTheScreenDropsTheListenerThenClosesTheController() throws {
        let events = Events()
        var store: SessionsStore? = try showing(events).0
        #expect(store != nil)
        events.log = []
        store = nil
        #expect(events.log == ["unlisten", "close"])
    }

    @Test func disappearingHidesAndAppearingAgainReusesTheController() throws {
        let events = Events()
        let (store, owner, _) = makeStore(events)
        store.setPresentationActive(true)
        store.setOnScreen(true)
        store.setOnScreen(false)
        store.setOnScreen(true)
        #expect(owner.opened.count == 1)
        #expect(events.log == ["open", "listen", "start", "visible true", "visible false", "visible true"])
    }

    // presentationActive drives SetForeground, and a backgrounded app (or a
    // hidden macOS window) stops the polling the screen's visibility runs
    @Test func theAppLifecycleDrivesForegroundAndPausesPolling() throws {
        let (store, _, _, events) = try showing()
        events.log = []
        store.setPresentationActive(false)
        store.setPresentationActive(true)
        #expect(events.log == ["foreground false", "visible false", "foreground true", "visible true"])
    }

    @Test func repeatedLifecycleCallsAreIgnored() throws {
        let (store, _, _, events) = try showing()
        events.log = []
        store.setPresentationActive(true)
        store.setOnScreen(true)
        #expect(events.log.isEmpty)
    }

    // §6: on dispose, unsubscribe, then Close()
    @Test func closeDropsTheListenerBeforeClosingTheController() throws {
        let (store, _, _, events) = try showing()
        events.log = []
        store.close()
        #expect(events.log == ["unlisten", "close"])
        store.close()
        store.setOnScreen(false)
        store.setOnScreen(true)
        store.refresh()
        #expect(events.log == ["unlisten", "close"])
    }

    @Test func aClosedStoreOpensNothing() {
        let events = Events()
        let (store, owner, _) = makeStore(events)
        store.close()
        store.setPresentationActive(true)
        store.setOnScreen(true)
        #expect(owner.opened.isEmpty)
        #expect(events.log.isEmpty)
    }

    // §6: no updates may land after disposal, including a hop already queued
    @Test func nothingLandsAfterClose() throws {
        let (store, controller, hops, _) = try showing()
        controller.publish(Self.twoSessions)
        store.close()
        hops.run()
        #expect(store.snapshot == SessionsSnapshot())

        // the controller posting again after its close
        controller.publish(Self.twoSessions)
        hops.run()
        #expect(store.snapshot == SessionsSnapshot())
        #expect(store.confirmation == nil)
    }

    // MARK: Snapshots

    @Test func aNotificationPublishesTheControllersSnapshot() throws {
        let (store, controller, hops, _) = try showing()
        controller.publish(Self.twoSessions)
        // nothing lands until the hop to the main queue runs
        #expect(store.snapshot == SessionsSnapshot())
        hops.run()
        #expect(store.snapshot == Self.twoSessions)
    }

    // §10 races: the SDK can deliver an older snapshot after a newer one (a
    // refresh and a sign-out completing on different threads); every hop
    // reads the newest, so the older one never comes back
    @Test func aLateNotificationNeverRestoresAnOlderSnapshot() throws {
        let (store, controller, hops, _) = try showing()
        let older = Self.twoSessions
        let newer = Self.loaded([Self.session(Self.thisSession, current: true, deviceType: "ios")])
        controller.publish(newer)
        hops.run()
        #expect(store.snapshot == newer)

        // the older publish's notification arriving last
        controller.listener?()
        hops.run()
        #expect(store.snapshot == newer)
        #expect(store.snapshot != older)
    }

    // §10 races: switching accounts while a request is pending. The old
    // screen is disposed with the old account; its controller's late answer
    // lands nowhere, and the newer account's screen keeps its own list.
    @Test func anOlderAccountsLateAnswerLeavesTheNewerScreenAlone() throws {
        let hops = Hops()
        let oldOwner = FakeOwner(Events())
        let oldStore = SessionsStore(owner: oldOwner, dispatch: hops.dispatch)
        oldStore.setPresentationActive(true)
        oldStore.setOnScreen(true)
        let oldController = try #require(oldOwner.opened.first)

        let newOwner = FakeOwner(Events())
        let newStore = SessionsStore(owner: newOwner, dispatch: hops.dispatch)

        // signed out: the old screen goes, then the new account's appears
        oldStore.close()
        newStore.setPresentationActive(true)
        newStore.setOnScreen(true)
        let newController = try #require(newOwner.opened.first)
        let newList = Self.loaded([Self.session(Self.thirdSession, current: true)])
        newController.publish(newList)

        oldController.publish(Self.twoSessions)
        hops.run()
        #expect(newStore.snapshot == newList)
        #expect(oldStore.snapshot == SessionsSnapshot())
    }

    // MARK: Refresh

    // the toolbar button, Try again and the pull all call Refresh()
    @Test func refreshCallsTheController() throws {
        let (store, _, _, events) = try showing()
        events.log = []
        store.refresh()
        #expect(events.log == ["refresh"])
    }

    @Test func pullToRefreshReturnsAtOnceWithoutAController() async {
        let (store, owner, _) = makeStore()
        await store.refreshAndWait()
        #expect(owner.opened.isEmpty)
    }

    // the pull indicator shows the snapshot's refreshing: it ends once the
    // refresh it asked for has finished, not on a notification queued earlier
    @Test func pullToRefreshWaitsForTheRefreshItAskedFor() async throws {
        let (store, controller, hops, events) = try showing()
        var refreshing = Self.twoSessions
        refreshing.refreshing = true
        // a notification posted before the pull, its hop not yet run
        controller.publish(Self.twoSessions)

        let finished = Flag()
        let pull = Task {
            await store.refreshAndWait()
            finished.value = true
        }
        await drainMainQueue()
        #expect(events.log.last == "refresh")

        hops.run()
        await drainMainQueue()
        #expect(!finished.value)

        controller.publish(refreshing)
        hops.run()
        await drainMainQueue()
        #expect(!finished.value)

        controller.publish(Self.twoSessions)
        hops.run()
        await pull.value
        #expect(finished.value)
    }

    // a refresh that finished before its first notification was read
    @Test func pullToRefreshEndsWhenTheRefreshAlreadyFinished() async throws {
        let (store, controller, hops, _) = try showing()
        controller.onRefresh = {
            var refreshing = Self.twoSessions
            refreshing.refreshing = true
            controller.publish(refreshing)
            controller.publish(Self.twoSessions)
        }
        let pull = Task {
            await store.refreshAndWait()
        }
        await drainMainQueue()
        hops.run()
        await pull.value
        #expect(store.snapshot == Self.twoSessions)
    }

    @Test func pullToRefreshEndsWhenTheScreenIsDisposed() async throws {
        let (store, _, _, _) = try showing()
        let pull = Task {
            await store.refreshAndWait()
        }
        await drainMainQueue()
        store.close()
        await pull.value
    }

    // MARK: Signing out

    @Test func signOutAsksBeforeAnythingIsSignedOut() throws {
        let (store, controller, hops, events) = try showing()
        controller.publish(Self.twoSessions)
        hops.run()
        events.log = []

        store.requestSignOut(sessionId: Self.otherSession)
        #expect(store.confirmation == .signOut(
            sessionId: Self.otherSession,
            device: "Android",
            place: "Springfield, Illinois, United States",
            current: false
        ))
        #expect(events.log.isEmpty)
    }

    @Test func cancelSignsNothingOut() throws {
        let (store, controller, hops, events) = try showing()
        controller.publish(Self.twoSessions)
        hops.run()
        events.log = []

        store.requestSignOut(sessionId: Self.otherSession)
        store.cancelConfirmation()
        #expect(store.confirmation == nil)
        #expect(events.log.isEmpty)
    }

    // confirm calls RevokeSession; the controller marks the action before it
    // returns, so the row shows Signing out… without waiting for a hop
    @Test func confirmSignsThatSessionOutAndShowsItAtOnce() throws {
        let (store, controller, hops, events) = try showing()
        controller.publish(Self.twoSessions)
        hops.run()
        controller.onRevoke = { sessionId in
            controller.snapshot.actions = [SessionActionItem(sessionId: sessionId, loading: true)]
        }
        events.log = []

        store.requestSignOut(sessionId: Self.otherSession)
        let confirmation = try #require(store.confirmation)
        store.confirm(confirmation)

        #expect(events.log == ["revoke \(Self.otherSession)"])
        #expect(store.confirmation == nil)
        let row = try #require(store.snapshot.rows(now: Date(), format: SessionTimeFormat()).first { $0.id == Self.otherSession })
        #expect(row.signingOut)
        #expect(!row.signOutFailed)
    }

    // §10: duplicate activation is suppressed while the sign-out runs
    @Test func aSessionSigningOutIsNotAskedForAgain() throws {
        let (store, controller, hops, events) = try showing()
        var signingOut = Self.twoSessions
        signingOut.actions = [SessionActionItem(sessionId: Self.otherSession, loading: true)]
        controller.publish(signingOut)
        hops.run()
        events.log = []

        store.requestSignOut(sessionId: Self.otherSession)
        #expect(store.confirmation == nil)

        // 202 accepted and pending enforcement
        var pending = Self.twoSessions
        pending.actions = [SessionActionItem(sessionId: Self.otherSession, pending: true)]
        controller.publish(pending)
        hops.run()
        store.requestSignOut(sessionId: Self.otherSession)
        #expect(store.confirmation == nil)
        #expect(events.log.isEmpty)
    }

    // §4: a 202 stays pending until the controller confirms enforcement; its
    // next snapshot drops the row. Nothing declares completion before that.
    @Test func aPendingSignOutShowsProgressUntilTheControllerDropsTheRow() throws {
        let (store, controller, hops, _) = try showing()
        var pending = Self.twoSessions
        pending.actions = [SessionActionItem(sessionId: Self.otherSession, pending: true)]
        controller.publish(pending)
        hops.run()
        let rows = store.snapshot.rows(now: Date(), format: SessionTimeFormat())
        #expect(rows.map(\.id) == [Self.thisSession, Self.otherSession])
        #expect(rows.map(\.signingOut) == [false, true])

        var enforced = Self.loaded([Self.session(Self.thisSession, current: true, deviceType: "ios")])
        enforced.actions = [SessionActionItem(sessionId: Self.otherSession)]
        controller.publish(enforced)
        hops.run()
        #expect(store.snapshot.rows(now: Date(), format: SessionTimeFormat()).map(\.id) == [Self.thisSession])
    }

    // the action error shows on its row; a retry asks again and goes to the
    // controller, which reuses the operation
    @Test func aFailedSignOutShowsOnItsRowAndCanBeTriedAgain() throws {
        let (store, controller, hops, events) = try showing()
        var failed = Self.twoSessions
        failed.actions = [SessionActionItem(sessionId: Self.otherSession, error: SessionErrorItem(retryable: false))]
        controller.publish(failed)
        hops.run()
        let row = try #require(store.snapshot.rows(now: Date(), format: SessionTimeFormat()).first { $0.id == Self.otherSession })
        #expect(row.signOutFailed)
        #expect(!row.signingOut)
        events.log = []

        store.requestSignOut(sessionId: Self.otherSession)
        let confirmation = try #require(store.confirmation)
        store.confirm(confirmation)
        #expect(events.log == ["revoke \(Self.otherSession)"])
    }

    // the current session can be signed out from the list, with the warning
    // that this app signs out (the controller then rejects the account
    // credential and the app's own logout flow follows)
    @Test func signingOutThisSessionWarnsThatTheAppSignsOut() throws {
        let (store, controller, hops, events) = try showing()
        controller.publish(Self.twoSessions)
        hops.run()
        events.log = []

        store.requestSignOut(sessionId: Self.thisSession)
        let confirmation = try #require(store.confirmation)
        #expect(confirmation == .signOut(
            sessionId: Self.thisSession,
            device: "iOS",
            place: "Springfield, Illinois, United States",
            current: true
        ))
        #expect(confirmation.message == "This is the session you're using. This app will be signed out.")
        store.confirm(confirmation)
        #expect(events.log == ["revoke \(Self.thisSession)"])
    }

    // a row the list no longer has (signed out elsewhere) asks nothing; a
    // stale row's 404 is the controller's to refresh
    @Test func aSessionNoLongerListedAsksNothing() throws {
        let (store, controller, hops, _) = try showing()
        controller.publish(Self.twoSessions)
        hops.run()
        store.requestSignOut(sessionId: Self.thirdSession)
        #expect(store.confirmation == nil)
    }

    @Test func confirmingAfterTheScreenClosedSignsNothingOut() throws {
        let (store, controller, hops, events) = try showing()
        controller.publish(Self.twoSessions)
        hops.run()
        store.requestSignOut(sessionId: Self.otherSession)
        let confirmation = try #require(store.confirmation)
        store.close()
        events.log = []
        store.confirm(confirmation)
        #expect(events.log.isEmpty)
    }

    // §4: offered only with this app's session and at least one other
    @Test func signOutOthersIsOfferedOnlyWithThisSessionAndAnother() throws {
        let (store, controller, hops, _) = try showing()

        controller.publish(Self.loaded([Self.session(Self.thisSession, current: true)]))
        hops.run()
        #expect(!store.snapshot.showsSignOutOthers)
        store.requestSignOutOthers()
        #expect(store.confirmation == nil)

        // no current session in the list
        controller.publish(Self.loaded([Self.session(Self.otherSession), Self.session(Self.thirdSession)]))
        hops.run()
        #expect(!store.snapshot.showsSignOutOthers)
        store.requestSignOutOthers()
        #expect(store.confirmation == nil)

        controller.publish(Self.twoSessions)
        hops.run()
        #expect(store.snapshot.showsSignOutOthers)
    }

    @Test func signOutOthersAsksThenSignsTheOthersOut() throws {
        let (store, controller, hops, events) = try showing()
        controller.publish(Self.twoSessions)
        hops.run()
        controller.onRevoke = { _ in
            controller.snapshot.bulkAction = SessionActionItem(loading: true)
        }
        events.log = []

        store.requestSignOutOthers()
        let confirmation = try #require(store.confirmation)
        #expect(confirmation == .signOutOthers)
        #expect(events.log.isEmpty)
        store.confirm(confirmation)
        #expect(events.log == ["revoke others"])
        #expect(store.snapshot.signingOutOthers)

        // while it runs the button asks nothing
        store.requestSignOutOthers()
        #expect(store.confirmation == nil)
        #expect(events.log == ["revoke others"])
    }

    // the bulk sign-out failed: it says so under the button, which another
    // try asks again for and hands to the controller (it reuses the
    // operation), and the line goes while that try runs
    @Test func aFailedSignOutOfTheOtherSessionsSaysSoAndCanBeTriedAgain() throws {
        let (store, controller, hops, events) = try showing()
        var failed = Self.twoSessions
        failed.bulkAction = SessionActionItem(error: SessionErrorItem(retryable: true))
        controller.publish(failed)
        hops.run()
        #expect(store.snapshot.showsSignOutOthers)
        #expect(store.snapshot.signOutOthersFailedMessage == "Couldn't sign out the other sessions. Try again.")
        controller.onRevoke = { _ in
            controller.snapshot.bulkAction = SessionActionItem(loading: true)
        }
        events.log = []

        store.requestSignOutOthers()
        let confirmation = try #require(store.confirmation)
        #expect(confirmation == .signOutOthers)
        store.confirm(confirmation)
        #expect(events.log == ["revoke others"])
        #expect(store.snapshot.signingOutOthers)
        #expect(store.snapshot.signOutOthersFailedMessage == nil)
    }

    // the controller's sign-in-required error replaces the list with the
    // sign-in state, not the load-failed one
    @Test func aRejectedSignInShowsTheSignInState() throws {
        let (store, controller, hops, _) = try showing()
        controller.publish(Self.twoSessions)
        hops.run()
        #expect(store.snapshot.content == .list)

        var rejected = SessionsSnapshot()
        rejected.error = SessionErrorItem(signInRequired: true)
        controller.publish(rejected)
        hops.run()
        #expect(store.snapshot.content == .signInRequired)
        #expect(store.snapshot.signInRequiredMessage == "Sign in again to manage sessions.")
    }
}
