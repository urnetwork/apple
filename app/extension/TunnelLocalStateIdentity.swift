import Foundation

// String-returning gomobile methods retain NSErrorPointer in their Swift
// import. Never accept the returned value until the same call's error is read.
func checkedTunnelSdkValue<Value>(_ call: (NSErrorPointer) -> Value) throws -> Value {
    var error: NSError?
    let value = call(&error)
    if let error { throw error }
    return value
}

// The SDK deliberately exports this fixed failure through NSError. Only
// superseded/unsettled observations are recaptured; filesystem and decoding
// failures, native ticket changes, constructors and resets are never retried.
func withCurrentTunnelAuthObservation<Value>(
    isCurrent: () -> Bool,
    superseded: () -> Void,
    observe: () throws -> Value
) throws -> Value {
    for attempt in 0..<3 {
        guard isCurrent() else { throw TunnelLocalAuthIdentityError.superseded }
        do { return try observe() }
        catch {
            guard (error as NSError).localizedDescription == "auth snapshot was superseded or is not settled",
                  attempt < 2, isCurrent() else { throw error }
            superseded()
        }
    }
    throw TunnelLocalAuthIdentityError.superseded
}

enum TunnelAuthStartupError: Error { case deadline }

// The provider reserves before constructing SDK work and publishes only into
// that reservation. Stop/take also retires an empty reservation, so a slow old
// constructor cannot overwrite a newer start. Values contain session references
// and cleanup closures; all SDK/cleanup calls and capture releases occur outside
// this short lock. Update closures only assign already-prepared native values.
// Preparation runs under this owner lock and may only change the provider's
// packet/settings/recovery bookkeeping (owner lock precedes their locks).
// It must retain detached callbacks until return, never invoke them or reenter
// this owner. Thus an admitted publication cannot later begin a stale session.
final class TunnelProviderSessionOwner<Value> {
    struct Ticket: Equatable { fileprivate let generation: UInt64 }
    struct LogoutTicket: Hashable { fileprivate let generation: UInt64 }
    struct Snapshot {
        let ticket: Ticket
        let value: Value
    }
    enum StartupAdmission {
        case alreadyRunning
        case unavailable
        case reserved(ticket: Ticket, previous: Value?)
    }
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var currentTicket: Ticket?
    private var value: Value?
    private var logouts: Set<LogoutTicket> = []

    func begin(prepareWithLock: () -> Void = {}) -> (Ticket, Value?)? {
        lock.lock()
        guard logouts.isEmpty else { lock.unlock(); return nil }
        let previous = value
        generation &+= 1
        let ticket = Ticket(generation: generation)
        currentTicket = ticket
        value = nil
        prepareWithLock()
        lock.unlock()
        return (ticket, previous)
    }

    // Matching starts leave recovery untouched. Only an admitted reservation
    // queues cancellation, and its ticket must still own startup at execution.
    // The SDK-backed predicate, enqueue and cancellation run outside this lock.
    // The caller supplies main-queue execution for its recovery bookkeeping.
    func beginStartup(
        isAlreadyRunning: (Value) -> Bool,
        prepareWithLock: () -> Void = {},
        enqueue: (@escaping () -> Void) -> Void,
        cancelRecovery: @escaping () -> Void
    ) -> StartupAdmission {
        if let existing = snapshot()?.value, isAlreadyRunning(existing) {
            return .alreadyRunning
        }
        guard let (ticket, previous) = begin(prepareWithLock: prepareWithLock) else {
            return .unavailable
        }
        enqueue { [weak self] in
            guard self?.isCurrent(ticket) == true else { return }
            cancelRecovery()
        }
        return .reserved(ticket: ticket, previous: previous)
    }

    func isCurrent(_ ticket: Ticket) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return currentTicket == ticket
    }

    func snapshot(ticket: Ticket? = nil) -> Snapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard let currentTicket, let value, ticket == nil || ticket == currentTicket else { return nil }
        return Snapshot(ticket: currentTicket, value: value)
    }

    @discardableResult
    func publish(_ value: Value, ticket: Ticket, prepareWithLock: () -> Void = {}) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard currentTicket == ticket, self.value == nil else { return false }
        prepareWithLock()
        self.value = value
        return true
    }

    // A plan is built from the retained originating value before this call.
    // Only callback-free queue bookkeeping runs here; old prepared work cannot
    // join a replacement's active queue after an earlier isCurrent check.
    @discardableResult
    func admitPrepared(_ ticket: Ticket, enqueueWithLock: () -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard currentTicket == ticket, value != nil else { return false }
        enqueueWithLock()
        return true
    }

    @discardableResult
    func update(_ ticket: Ticket, _ assign: (inout Value) -> Void) -> Bool {
        lock.lock()
        guard currentTicket == ticket, var next = value else { lock.unlock(); return false }
        let previous = value
        assign(&next)
        value = next
        lock.unlock()
        withExtendedLifetime(previous) {}
        return true
    }

    @discardableResult
    func take(_ ticket: Ticket? = nil, prepareWithLock: () -> Void = {}) -> Value? {
        lock.lock()
        guard ticket == nil || ticket == currentTicket else { lock.unlock(); return nil }
        let previous = value
        currentTicket = nil
        value = nil
        generation &+= 1
        prepareWithLock()
        lock.unlock()
        return previous
    }

    // Explicit user logout is not a stale auth callback. It retires even an
    // empty startup reservation and bars new starts until outside-lock clears
    // return. Distinct tokens make overlapping logout completion idempotent.
    // This does not preempt an already-running SDK constructor or give this
    // native owner a cross-manager/storage lease.
    func beginLogout(prepareWithLock: () -> Void = {}) -> (LogoutTicket, Value?) {
        lock.lock()
        let previous = value
        generation &+= 1
        let ticket = LogoutTicket(generation: generation)
        logouts.insert(ticket)
        currentTicket = nil
        value = nil
        prepareWithLock()
        lock.unlock()
        return (ticket, previous)
    }

    @discardableResult
    func finishLogout(_ ticket: LogoutTicket) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return logouts.remove(ticket) != nil
    }

    // The explicit command's storage/cleanup boundary is outside every owner
    // lock. Its admission ends before the caller sends the command reply.
    func withLogout(
        prepareWithLock: () -> Void = {}, clear: (Value?) throws -> Void
    ) rethrows {
        let (ticket, previous) = beginLogout(prepareWithLock: prepareWithLock)
        defer { finishLogout(ticket) }
        try clear(previous)
    }
}

// The actual packet-reader generation gate. Session admission may begin/stop
// it under the provider owner lock; packet callbacks only take this short lock
// and release it before consulting a provider or invoking SDK/NE operations.
final class TunnelPacketReadOwner {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var stopped = true

    func begin() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        generation &+= 1
        stopped = false
        return generation
    }

    func stop(generation expectedGeneration: UInt64? = nil) {
        lock.lock()
        defer { lock.unlock() }
        guard expectedGeneration == nil || expectedGeneration == generation else { return }
        generation &+= 1
        stopped = true
    }

    func isActive(generation expectedGeneration: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !stopped && generation == expectedGeneration
    }
}

// A packet callback retains its original device. Generation admission rejects
// already-retired work; retirement after admission still cannot redirect that
// work into a newer device. Delivery is outside the packet-owner lock.
struct TunnelPacketReadOrigin<Device> {
    let device: Device
    let generation: UInt64

    @discardableResult
    func withActiveDevice(_ owner: TunnelPacketReadOwner, deliver: (Device) -> Void) -> Bool {
        guard owner.isActive(generation: generation) else { return false }
        deliver(device)
        return true
    }
}

// Subscribe before observing. Only a successful SDK refresh event can resume
// an unsettled startup; an event during the read is remembered before parking.
// Short-lock state is safe across SDK, lifecycle and deadline callbacks. None
// of those callbacks runs a resumed observation or cleanup inline. Cancellation
// retires immediately; an already-running SDK call finishes before cleanup.
final class TunnelAuthStartupContinuation {
    struct FinishAdmission {
        let enqueue: (@escaping () -> Void) -> Void
        let isReady: () throws -> Bool
    }

    private struct Configuration {
        let enqueue: (@escaping () -> Void) -> Void
        let subscribe: (@escaping () -> Void, @escaping () -> Void) -> (() -> Void)
        let scheduleDeadline: (@escaping () -> Void) -> (() -> Void)
        let isCurrent: () -> Bool
        let observe: () throws -> Void
        let finishAdmission: FinishAdmission?
        let waiting: () -> Void
        let completion: (Result<Void, Error>) -> Void
    }
    private struct Delivery {
        let configuration: Configuration
        let cancelSubscription: (() -> Void)?
        let cancelDeadline: (() -> Void)?
        let result: Result<Void, Error>

        func run() {
            cancelSubscription?()
            cancelDeadline?()
            configuration.completion(result)
        }
    }
    private let lock = NSLock()
    private var configuration: Configuration?
    private var started = false
    private var running = false
    private var queued = false
    private var waiting = false
    private var settlementGeneration: UInt64 = 0
    private var finishGeneration: UInt64 = 0
    private var queuedFinish: UInt64?
    private var terminal: Result<Void, Error>?
    private var cancelSubscription: (() -> Void)?
    private var cancelDeadline: (() -> Void)?

    init(
        enqueue: @escaping (@escaping () -> Void) -> Void,
        subscribe: @escaping (@escaping () -> Void, @escaping () -> Void) -> (() -> Void),
        scheduleDeadline: @escaping (@escaping () -> Void) -> (() -> Void),
        isCurrent: @escaping () -> Bool, observe: @escaping () throws -> Void,
        finishAdmission: FinishAdmission? = nil,
        waiting: @escaping () -> Void = {},
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        configuration = Configuration(
            enqueue: enqueue, subscribe: subscribe, scheduleDeadline: scheduleDeadline,
            isCurrent: isCurrent, observe: observe, finishAdmission: finishAdmission,
            waiting: waiting, completion: completion
        )
    }

    // A healthy first observation remains synchronous. All later attempts are
    // queued outside the SDK listener; there is no timer-driven polling.
    func start() {
        lock.lock()
        guard !started, terminal == nil, let configuration else { lock.unlock(); return }
        started = true
        lock.unlock()
        installCancellation(configuration.subscribe(
            { [weak self] in self?.settled() }, { [weak self] in self?.cancel() }
        ), subscription: true)
        installCancellation(configuration.scheduleDeadline { [weak self] in
            self?.terminate(.failure(TunnelAuthStartupError.deadline))
        }, subscription: false)
        runAttempt()
    }

    func cancel() { terminate(.failure(TunnelLocalAuthIdentityError.superseded)) }

    private func installCancellation(_ cancel: @escaping () -> Void, subscription: Bool) {
        lock.lock()
        let finished = terminal != nil
        if !finished {
            if subscription { cancelSubscription = cancel }
            else { cancelDeadline = cancel }
        }
        lock.unlock()
        if finished { cancel() }
    }

    private func settled() {
        lock.lock()
        guard terminal == nil, let configuration else { lock.unlock(); return }
        settlementGeneration &+= 1
        let resume = waiting && !running && !queued
        if resume { queued = true; waiting = false }
        lock.unlock()
        if resume { configuration.enqueue { [weak self] in self?.runAttempt() } }
    }

    private func runAttempt() {
        lock.lock()
        guard terminal == nil, !running, queuedFinish == nil, let configuration else { lock.unlock(); return }
        running = true
        queued = false
        waiting = false
        let observedGeneration = settlementGeneration
        lock.unlock()

        let result: Result<Void, Error>
        do {
            guard configuration.isCurrent() else { throw TunnelLocalAuthIdentityError.superseded }
            try configuration.observe()
            guard configuration.isCurrent() else { throw TunnelLocalAuthIdentityError.superseded }
            result = .success(())
        } catch {
            result = configuration.isCurrent() ? .failure(error) : .failure(TunnelLocalAuthIdentityError.superseded)
        }
        let unsettled: Bool
        if case .failure(let error) = result {
            unsettled = (error as NSError).localizedDescription == "auth snapshot was superseded or is not settled"
        } else { unsettled = false }

        lock.lock()
        running = false
        var resume = false
        var awaitingSettlement = false
        var finish: (FinishAdmission, UInt64)?
        if terminal == nil {
            if case .success = result, let admission = configuration.finishAdmission {
                finishGeneration &+= 1
                queuedFinish = finishGeneration
                finish = (admission, finishGeneration)
            } else if unsettled {
                resume = settlementGeneration != observedGeneration
                queued = resume
                waiting = !resume
                awaitingSettlement = true
            } else {
                terminal = result
            }
        }
        let delivery = takeDeliveryWithLock()
        lock.unlock()
        if let delivery {
            if case .success = delivery.result { delivery.run() }
            else { delivery.configuration.enqueue { delivery.run() } }
        } else if let (admission, token) = finish {
            // Retain only this small owner and the token while queued, not
            // configuration/SDK captures. Cancel/deadline can deliver on the
            // worker without waiting for this queue to drain.
            admission.enqueue { [self] in runFinishAdmission(token) }
        } else if awaitingSettlement {
            configuration.waiting()
            if resume { configuration.enqueue { [weak self] in self?.runAttempt() } }
        }
    }

    private func runFinishAdmission(_ token: UInt64) {
        lock.lock()
        guard terminal == nil, !running, queuedFinish == token,
              let configuration, let admission = configuration.finishAdmission else {
            lock.unlock()
            return
        }
        queuedFinish = nil
        running = true
        lock.unlock()

        let result: Result<Bool, Error>
        do {
            guard configuration.isCurrent() else { throw TunnelLocalAuthIdentityError.superseded }
            let ready = try admission.isReady()
            guard configuration.isCurrent() else { throw TunnelLocalAuthIdentityError.superseded }
            result = .success(ready)
        } catch {
            result = configuration.isCurrent() ? .failure(error) : .failure(TunnelLocalAuthIdentityError.superseded)
        }

        lock.lock()
        running = false
        var resume = false
        if terminal == nil {
            switch result {
            case .success(true): terminal = .success(())
            case .success(false):
                queued = true
                resume = true
            case .failure(let error): terminal = .failure(error)
            }
        }
        let delivery = takeDeliveryWithLock()
        lock.unlock()
        if let delivery {
            // Success stays on this admitted stack: another main-queue hop
            // would reopen the shared-intent handoff. Failure/SDK cleanup
            // remains on the existing worker, after any admitted read ends.
            if case .success = delivery.result { delivery.run() }
            else { delivery.configuration.enqueue { delivery.run() } }
        } else if resume {
            configuration.enqueue { [weak self] in self?.runAttempt() }
        }
    }

    private func terminate(_ result: Result<Void, Error>) {
        lock.lock()
        if terminal == nil { terminal = result }
        queuedFinish = nil
        let delivery = takeDeliveryWithLock()
        lock.unlock()
        if let delivery { delivery.configuration.enqueue { delivery.run() } }
    }

    // All callback captures are transferred to Delivery before fields clear;
    // their releases and cancellation/completion calls happen after unlock.
    private func takeDeliveryWithLock() -> Delivery? {
        guard !running, let terminal, let configuration else { return nil }
        let delivery = Delivery(
            configuration: configuration, cancelSubscription: cancelSubscription,
            cancelDeadline: cancelDeadline, result: terminal
        )
        self.configuration = nil
        queuedFinish = nil
        cancelSubscription = nil
        cancelDeadline = nil
        return delivery
    }
}

// These are fields from one immutable SDK operation, never its later global
// result. A committed file can be followed by failed live application. Disabled
// autosave is neither a successful commit nor an I/O failure. Error contents
// and caller-provided preference names never enter the fixed stage vocabulary.
@discardableResult
func reportTunnelPreferenceSave(
    preference: String, autoSaveEnabled: Bool, saved: Bool, hasError: Bool,
    report: (String, String) -> Void
) -> Bool {
    let prefix: String
    switch preference {
    case "connect-location": prefix = "destination"
    case "default-location": prefix = "default"
    default: return false
    }
    guard autoSaveEnabled else {
        report("auto-save", "disabled")
        return false
    }
    report(prefix + "-persist", saved ? "completed" : "failed")
    guard saved else { return false }
    report(prefix + "-apply", hasError ? "failed" : "applied")
    return !hasError
}

func requireTunnelResetCompleted(_ completed: Bool) throws {
    guard completed else { throw TunnelLocalAuthIdentityError.superseded }
}

// Short-lock transition ownership; NE lifecycle calls need not run on main.
// No SDK, settings or callback work runs under this lock. Only a successful
// current completion is cached as applied. One failed level may request one
// settings-only nudge; later owned events can still retry, without a reset loop.
final class TunnelReadinessOwner {
    struct State: Equatable {
        let readiness: TunnelReadiness
        let dnsOwned: Bool
    }
    struct Ticket: Equatable {
        let state: State
        let generation: UInt64
    }
    enum Completion: Equatable { case stale, applied, failed(retry: Bool) }

    private let lock = NSLock()
    private var generationValue: UInt64 = 0
    private var pending: Ticket?
    private var applied: State?
    private var lastRequested: State?
    private var retrySpent = false

    var generation: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return generationValue
    }

    func begin(_ state: State) -> Ticket? {
        lock.lock()
        defer { lock.unlock() }
        if let pending {
            guard pending.state != state else { return nil }
        } else if applied == state { return nil }
        if lastRequested != state { retrySpent = false }
        lastRequested = state
        generationValue &+= 1
        let ticket = Ticket(state: state, generation: generationValue)
        pending = ticket
        return ticket
    }

    func complete(_ ticket: Ticket, succeeded: Bool) -> Completion {
        lock.lock()
        defer { lock.unlock() }
        guard pending == ticket else { return .stale }
        pending = nil
        if succeeded {
            applied = ticket.state
            retrySpent = false
            return .applied
        }
        applied = nil
        let retry = !retrySpent
        retrySpent = true
        return .failed(retry: retry)
    }

    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        generationValue &+= 1
        pending = nil
        applied = nil
        lastRequested = nil
        retrySpent = false
    }
}

// NE lifecycle callbacks and main-queue listeners share only this introduced
// recovery state. A snapshot retains its callbacks; callers invoke them after
// the lock has been released. Session and destination tickets reject late
// publication without holding a native lock across SDK/storage/settings work.
final class TunnelRecoverySession<Owner, Intent> {
    struct Ticket: Equatable { fileprivate let generation: UInt64 }
    struct DestinationTicket: Equatable {
        let session: Ticket
        fileprivate let generation: UInt64
    }
    struct Diagnostics {
        let consumerPresent: Bool
        let hasLocation: Bool
        let providerCount: Int64
    }
    struct Snapshot {
        let ticket: Ticket
        let owner: Owner?
        let readiness = TunnelReadinessOwner()
        let readDiagnostics: (() -> Diagnostics)?
        var connectIntended = false
        var observedIntent: Intent?
        var liveDisconnectAt: Date?
        var savedLocationHasCurrentOwner: Bool
        var defaultPreferenceUnavailable = false
        var authStartup: TunnelAuthStartupContinuation?
        var restoreDestination: (() throws -> Void)?
        var reconcileReadiness: (() -> Void)?
        fileprivate var destinationGeneration: UInt64 = 0

        var destinationTicket: DestinationTicket {
            DestinationTicket(session: ticket, generation: destinationGeneration)
        }
    }

    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var current: Snapshot?

    func begin(
        owner: Owner?, savedLocationHasCurrentOwner: Bool,
        readDiagnostics: (() -> Diagnostics)? = nil
    ) -> Ticket {
        let (ticket, previous) = prepareBegin(
            owner: owner, savedLocationHasCurrentOwner: savedLocationHasCurrentOwner,
            readDiagnostics: readDiagnostics
        )
        completeRetirement(previous)
        return ticket
    }

    // Preparation detaches state only. A composing provider admission must
    // complete retirement after releasing its own lock as well as this one.
    func prepareBegin(
        owner: Owner?, savedLocationHasCurrentOwner: Bool,
        readDiagnostics: (() -> Diagnostics)? = nil
    ) -> (Ticket, Snapshot?) {
        lock.lock()
        let previous = current
        generation &+= 1
        let ticket = Ticket(generation: generation)
        current = Snapshot(
            ticket: ticket, owner: owner, readDiagnostics: readDiagnostics,
            savedLocationHasCurrentOwner: savedLocationHasCurrentOwner
        )
        lock.unlock()
        return (ticket, previous)
    }

    func completeRetirement(_ previous: Snapshot?) {
        previous?.authStartup?.cancel()
        previous?.readiness.invalidate()
    }

    func snapshot(ticket: Ticket? = nil) -> Snapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard let current, ticket == nil || ticket == current.ticket else { return nil }
        return current
    }

    func isCurrent(_ ticket: Ticket) -> Bool { snapshot(ticket: ticket) != nil }

    func isCurrent(_ ticket: DestinationTicket) -> Bool {
        snapshot(ticket: ticket.session)?.destinationTicket == ticket
    }

    // The checked shared-intent read is the startup finish cutoff, not an
    // ongoing watcher. Fence its originating destination before and after
    // I/O; the reader and queue run outside the recovery-session lock.
    func startupFinishAdmission(
        ticket: Ticket,
        enqueue: @escaping (@escaping () -> Void) -> Void,
        readIntent: @escaping () throws -> Intent?
    ) -> TunnelAuthStartupContinuation.FinishAdmission where Intent: Equatable {
        TunnelAuthStartupContinuation.FinishAdmission(enqueue: enqueue, isReady: { [weak self] in
            guard let self, let state = self.snapshot(ticket: ticket) else {
                throw TunnelLocalAuthIdentityError.superseded
            }
            let intent = try readIntent()
            guard self.isCurrent(state.destinationTicket) else {
                throw TunnelLocalAuthIdentityError.superseded
            }
            return intent == state.observedIntent
        })
    }

    @discardableResult
    func retire(_ ticket: Ticket? = nil) -> Snapshot? {
        let previous = prepareRetire(ticket)
        completeRetirement(previous)
        return previous
    }

    func prepareRetire(_ ticket: Ticket? = nil) -> Snapshot? {
        lock.lock()
        guard let previous = current, ticket == nil || ticket == previous.ticket else {
            lock.unlock()
            return nil
        }
        current = nil
        generation &+= 1
        lock.unlock()
        return previous
    }

    @discardableResult
    func installAuthStartup(_ startup: TunnelAuthStartupContinuation, ticket: Ticket) -> Bool {
        mutate(ticket) { $0.authStartup = startup }
    }

    @discardableResult
    func clearAuthStartup(_ ticket: Ticket) -> Bool {
        mutate(ticket) { $0.authStartup = nil }
    }

    @discardableResult
    func installCallbacks(
        ticket: Ticket, restoreDestination: @escaping () throws -> Void,
        reconcileReadiness: @escaping () -> Void
    ) -> Bool {
        mutate(ticket) {
            $0.restoreDestination = { [weak self] in
                guard self?.isCurrent(ticket) == true else {
                    throw TunnelLocalAuthIdentityError.superseded
                }
                try restoreDestination()
            }
            $0.reconcileReadiness = { [weak self] in
                guard self?.isCurrent(ticket) == true else { return }
                reconcileReadiness()
            }
        }
    }

    func noteDestinationChange(ticket: Ticket) -> DestinationTicket? {
        var result: DestinationTicket?
        _ = mutate(ticket) {
            $0.destinationGeneration &+= 1
            result = $0.destinationTicket
        }
        return result
    }

    @discardableResult
    func observeLocation(_ ticket: DestinationTicket, present: Bool, at date: Date) -> Bool {
        mutate(ticket.session, destinationGeneration: ticket.generation) {
            $0.connectIntended = present
            $0.liveDisconnectAt = present ? nil : date
        }
    }

    // Called after observeLocation(nil). The nil decision is already admitted
    // before I/O; a failed read leaves both it and the prior observation intact.
    @discardableResult
    func observeIntentAfterLiveDisconnect(
        _ ticket: DestinationTicket, readIntent: () throws -> Intent?
    ) throws -> Bool {
        guard let state = snapshot(ticket: ticket.session),
              state.destinationTicket == ticket,
              let disconnectedAt = state.liveDisconnectAt else { return false }
        var date = state.liveDisconnectAt
        var observed = state.observedIntent
        try recordTunnelLiveDisconnect(
            at: disconnectedAt, readIntent: readIntent,
            liveDisconnectAt: &date, observedIntent: &observed
        )
        return mutate(ticket.session, destinationGeneration: ticket.generation) {
            $0.observedIntent = observed
        }
    }

    @discardableResult
    func acceptDestination(
        _ ticket: DestinationTicket, present: Bool, observedIntent: Intent?,
        savedLocationIsVerified: Bool = true
    ) -> Bool {
        mutate(ticket.session, destinationGeneration: ticket.generation) {
            $0.connectIntended = present
            if present {
                $0.liveDisconnectAt = nil
                if savedLocationIsVerified { $0.savedLocationHasCurrentOwner = true }
            }
            $0.observedIntent = observedIntent
        }
    }

    @discardableResult
    func savedLocationPersisted(_ ticket: DestinationTicket) -> Bool {
        mutate(ticket.session, destinationGeneration: ticket.generation) {
            $0.savedLocationHasCurrentOwner = true
        }
    }

    // Startup records an optional Load failure before callbacks are exposed.
    // Only a later successful SDK default save makes that observation usable.
    @discardableResult
    func observeDefaultPreference(_ ticket: Ticket, unavailable: Bool) -> Bool {
        mutate(ticket) { $0.defaultPreferenceUnavailable = unavailable }
    }

    // Only the assignment-only methods above use this internal closure. Old
    // callback captures stay retained until after unlock, even on replacement.
    private func mutate(
        _ ticket: Ticket, destinationGeneration: UInt64? = nil,
        _ update: (inout Snapshot) -> Void
    ) -> Bool {
        lock.lock()
        guard var state = current, state.ticket == ticket,
              destinationGeneration == nil || destinationGeneration == state.destinationGeneration else {
            lock.unlock()
            return false
        }
        let previous = current
        update(&state)
        current = state
        lock.unlock()
        withExtendedLifetime(previous) {}
        return true
    }
}

// Remember the live disconnect even if observing the shared record fails.
// The prior record remains an observation, not an invented absent baseline.
func recordTunnelLiveDisconnect<Intent>(
    at date: Date,
    readIntent: () throws -> Intent?,
    liveDisconnectAt: inout Date?,
    observedIntent: inout Intent?
) throws {
    liveDisconnectAt = date
    let intent = try readIntent()
    observedIntent = intent
}

func tunnelConnectIntentIsNewer(changedAt: Date, liveDisconnectAt: Date?) -> Bool {
    liveDisconnectAt.map { $0 < changedAt } ?? true
}

// Shared debounce work distinguishes a settings-only nudge from an actual
// path recovery. Cancellation/supersession is admitted before every effect.
@discardableResult
func performTunnelRecovery(
    changeTransport: Bool,
    isCurrent: () -> Bool,
    restoreDestination: () throws -> Void,
    networkChanged: () -> Void,
    reconcileReadiness: () -> Void
) throws -> Bool {
    guard isCurrent() else { return false }
    if changeTransport {
        try restoreDestination()
        guard isCurrent() else { return false }
        networkChanged()
    }
    guard isCurrent() else { return false }
    reconcileReadiness()
    return true
}

// Matches the existing immutable shared-history ordering. Startup can include
// its profile candidate in memory without writing a speculative Keychain item.
struct TunnelStartupJwtCandidate {
    let account: String
    let byJwt: String
    let issuedAt: Int64?
    let expiresAt: Int64?

    static func freshest(
        _ candidates: [TunnelStartupJwtCandidate],
        now: Int64 = Int64(Date().timeIntervalSince1970)
    ) -> TunnelStartupJwtCandidate? {
        candidates.max { lhs, rhs in
            isPreferred(rhs, over: lhs, now: now)
        }
    }

    static func isPreferred(
        _ lhs: TunnelStartupJwtCandidate,
        over rhs: TunnelStartupJwtCandidate,
        now: Int64
    ) -> Bool {
        let lhsExpired = lhs.expiresAt.map { $0 <= now } ?? false
        let rhsExpired = rhs.expiresAt.map { $0 <= now } ?? false
        if lhsExpired != rhsExpired { return !lhsExpired }
        let lhsIssuedAt = lhs.issuedAt ?? Int64.min
        let rhsIssuedAt = rhs.issuedAt ?? Int64.min
        if lhsIssuedAt != rhsIssuedAt { return lhsIssuedAt > rhsIssuedAt }
        let lhsExpiresAt = lhs.expiresAt ?? Int64.min
        let rhsExpiresAt = rhs.expiresAt ?? Int64.min
        if lhsExpiresAt != rhsExpiresAt { return lhsExpiresAt > rhsExpiresAt }
        return lhs.account > rhs.account
    }
}

func selectTunnelStartupClient(
    configured: TunnelStartupJwtCandidate?,
    persisted: [TunnelStartupJwtCandidate],
    now: Int64 = Int64(Date().timeIntervalSince1970)
) -> String? {
    var candidates = persisted
    if let configured { candidates.append(configured) }
    return TunnelStartupJwtCandidate.freshest(candidates, now: now)?.byJwt
}

// One result-bearing auth generation. An absent store can be seeded; a
// nonempty store without a stable instance cannot authorize a destructive reset.
struct TunnelLocalAuthIdentitySnapshot {
    let isEmpty: Bool
    let instanceId: String?
    var knownClientOwnerConflict: Bool = false
}

enum TunnelLocalAuthIdentityError: Error {
    case unavailable
    case incomplete
    case superseded
}

// A renewable credential does not select the owner of persisted routing state.
// Only a coherent, different stable instance or known client-owner conflict
// authorizes clearing that state.
func tunnelLocalStateRequiresReset(
    snapshot: TunnelLocalAuthIdentitySnapshot,
    configuredInstanceId: String
) throws -> Bool {
    guard !configuredInstanceId.isEmpty else {
        throw TunnelLocalAuthIdentityError.incomplete
    }
    if snapshot.isEmpty {
        return false
    }
    guard let storedInstanceId = snapshot.instanceId, !storedInstanceId.isEmpty else {
        throw TunnelLocalAuthIdentityError.incomplete
    }
    return storedInstanceId != configuredInstanceId || snapshot.knownClientOwnerConflict
}

// Read-only auth selection and an authorized reset precede construction. The
// SDK commits auth at successful publication; later consumers must read the
// constructed device's client, which may supersede this preliminary selection.
func prepareTunnelLocalAuthState<Session>(
    configuredInstanceId: String,
    readAuthIdentity: () throws -> TunnelLocalAuthIdentitySnapshot,
    clearStaleState: () throws -> Void,
    selectClientJwt: () throws -> String,
    startSession: (String) throws -> Session
) throws -> Session {
    let snapshot = try readAuthIdentity()
    if try tunnelLocalStateRequiresReset(
        snapshot: snapshot,
        configuredInstanceId: configuredInstanceId
    ) {
        try clearStaleState()
    }
    let selectedClientJwt = try selectClientJwt()
    return try startSession(selectedClientJwt)
}

// The caller already owns device+manager cleanup. RPC must succeed before any
// restart handoff is published, and the device supplies the accepted client.
func finishTunnelLocalAuthSession(
    configureRpc: () throws -> Void,
    publishedClientJwt: () -> String,
    publishClient: (String) throws -> Void
) throws {
    try configureRpc()
    let clientJwt = publishedClientJwt()
    guard !clientJwt.isEmpty else {
        throw TunnelLocalAuthIdentityError.unavailable
    }
    try publishClient(clientJwt)
}

// Native intent is admitted before SDK replay. Auth that was initially empty
// cannot adopt orphan preferences just because construction seeded new auth.
// Autosave is explicit and must precede every subsequent intent/RPC mutation.
func loadTunnelPreferences<Result>(
    intent: TunnelDestinationIntent,
    loadOwnedPreferences: Bool,
    isCurrent: () throws -> Bool,
    persistDisconnect: () throws -> Void,
    load: () throws -> Result,
    enableAutoSave: () throws -> Void,
    report: (String, String) -> Void = { _, _ in }
) throws -> Result? {
    guard try isCurrent() else { throw TunnelLocalAuthIdentityError.superseded }
    if intent == .disconnect {
        do {
            try persistDisconnect()
            report("destination-persist", "completed")
        } catch {
            report("destination-persist", "failed")
            throw error
        }
    }
    guard try isCurrent() else { throw TunnelLocalAuthIdentityError.superseded }
    let result: Result?
    if loadOwnedPreferences {
        report("preferences-load", "started")
        do {
            result = try load()
            report("preferences-load", "completed")
        } catch {
            report("preferences-load", "failed")
            throw error
        }
    } else {
        result = nil
        report("preferences-load", "skipped-unowned")
    }
    guard try isCurrent() else { throw TunnelLocalAuthIdentityError.superseded }
    do {
        try enableAutoSave()
        report("auto-save", "enabled")
    } catch {
        report("auto-save", "failed")
        throw error
    }
    guard try isCurrent() else { throw TunnelLocalAuthIdentityError.superseded }
    return result
}

// These inputs are already scoped to the accepted owner by the caller. In
// particular, an old/unscoped connect request is .none, never .connect.
enum TunnelDestinationIntent: Equatable {
    case none
    case connect
    case disconnect
}

enum TunnelDestinationStage: String {
    case saved
    case sharedDefault = "shared-default"
    case sharedBestAvailable = "shared-best-available"
    case explicitDisconnect = "explicit-disconnect"
    case localOnly = "local-only"
}

struct TunnelDestinationPlan<Location> {
    let location: Location?
    let stage: TunnelDestinationStage
}

// Select from the SDK's explicitly loaded, accepted state. The operation-bearing
// apply closure uses the SDK's checked save-before-live mutation; native code
// never recreates a separate preference writer or persistence listener here.
@discardableResult
func restoreTunnelDestination<Location>(
    intent: TunnelDestinationIntent,
    savedLocationHasCurrentOwner: Bool,
    loadSaved: () throws -> Location?,
    loadDefault: () throws -> Location?,
    bestAvailable: () -> Location,
    isCurrent: () -> Bool,
    apply: (TunnelDestinationPlan<Location>) throws -> Void,
    report: (String, String) -> Void = { _, _ in }
) throws -> TunnelDestinationPlan<Location> {
    let plan: TunnelDestinationPlan<Location>
    if intent == .disconnect {
        plan = TunnelDestinationPlan(location: nil, stage: .explicitDisconnect)
    } else {
        let saved: Location?
        if savedLocationHasCurrentOwner {
            do {
                saved = try loadSaved()
                report("saved-load", saved == nil ? "missing" : "present")
            } catch {
                report("saved-load", "failed")
                throw error
            }
        } else {
            saved = nil
        }
        if let saved {
            plan = TunnelDestinationPlan(location: saved, stage: .saved)
        } else if intent == .connect {
            let defaultLocation: Location?
            if savedLocationHasCurrentOwner {
                do {
                    defaultLocation = try loadDefault()
                    report("default-load", defaultLocation == nil ? "missing" : "present")
                } catch {
                    report("default-load", "failed")
                    throw error
                }
            } else {
                defaultLocation = nil
            }
            if let defaultLocation {
                plan = TunnelDestinationPlan(location: defaultLocation, stage: .sharedDefault)
            } else {
                plan = TunnelDestinationPlan(location: bestAvailable(), stage: .sharedBestAvailable)
            }
        } else {
            plan = TunnelDestinationPlan(location: nil, stage: .localOnly)
        }
    }
    guard isCurrent() else { throw TunnelLocalAuthIdentityError.superseded }
    try apply(plan)
    report("consumer", plan.location == nil ? "local" : "accepted")
    return plan
}

enum TunnelReadiness: String {
    case local
    case establishing
    case connected
}

// The first observation always produces an action, including false -> false.
// Provider presence is not claimed as DNS ownership or end-to-end health.
func tunnelReadiness(
    connectIntended: Bool,
    consumerPresent: Bool,
    providerCount: Int
) -> TunnelReadiness {
    guard connectIntended || consumerPresent else { return .local }
    return consumerPresent && providerCount > 0 ? .connected : .establishing
}

enum TunnelWakeAction: Equatable {
    case local
    case restoreDestination
    case probeExisting
    case recoverTransport
    case coveredByPathRecovery
}

// An empty consumer window cannot be healthy merely because a probe had no
// exits to schedule. Path recovery covers transport work, not a missing client.
func tunnelWakeAction(
    connectIntended: Bool,
    destinationPresent: Bool,
    consumerPresent: Bool,
    providerCount: Int,
    afterGrace: Bool,
    pathRecoveryAlreadyRequested: Bool
) -> TunnelWakeAction {
    if connectIntended && (!destinationPresent || !consumerPresent) { return .restoreDestination }
    if !connectIntended && !consumerPresent { return .local }
    if pathRecoveryAlreadyRequested { return .coveredByPathRecovery }
    if afterGrace && providerCount <= 0 { return .recoverTransport }
    return .probeExisting
}

// No synthetic fallback without the SDK's factual current interceptor. Local
// mode leaves DNS to the existing OS configuration instead of claiming a mask
// that the extension cannot answer.
func tunnelOwnedDnsServers(interceptorPresent: Bool, advertised: [String]) -> [String] {
    interceptorPresent ? advertised : []
}

// The SDK close join cancels immediately in the common case. The short bound
// keeps NetworkExtension's completion edge unconditional if a native worker is
// stuck, while still making a clean stop's final log flush a true lifecycle
// boundary.
let tunnelStopCloseJoinTimeoutMilliseconds: Int64 = 250

enum TunnelStopReasonKind {
    case userDisabled
    case superseded
    case appUpdate
    case failure
    case other
}

func tunnelStopReasonClass(_ kind: TunnelStopReasonKind) -> String {
    switch kind {
    case .userDisabled: return "user-disabled"
    case .superseded: return "superseded"
    case .appUpdate: return "app-update"
    case .failure: return "failure"
    case .other: return "other"
    }
}

// Persist the successful startup edge before NetworkExtension can replace a
// process that has already reported the tunnel ready.
func finishTunnelStartup(
    recordOutcome: () -> Void,
    flushLogs: () -> Void,
    completion: () -> Void
) {
    recordOutcome()
    flushLogs()
    completion()
}

// NetworkExtension may reap the process as soon as its stop completion returns.
// Keep the sequence synchronous and join only through the bounded mobile SDK
// API. A timeout is recorded, then completion still runs unconditionally.
func finishTunnelStop(
    cleanup: () -> Void,
    joinCleanup: () -> Bool,
    reportCleanupJoin: (Bool) -> Void,
    sampleFinalState: () -> Void,
    flushLogs: () -> Void,
    completion: () -> Void
) {
    cleanup()
    reportCleanupJoin(joinCleanup())
    sampleFinalState()
    flushLogs()
    completion()
}
