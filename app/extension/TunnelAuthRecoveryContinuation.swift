import Foundation

// Only an already-requested wake/path may resume after auth publication. A
// settings-only retry has no destination observation and does not enter here.
struct TunnelDestinationRecoveryReason: OptionSet {
    let rawValue: Int
    static let path = Self(rawValue: 1 << 0)
    static let wake = Self(rawValue: 1 << 1)
    static let wakeGrace = Self(rawValue: 1 << 2)
}

// One current destination request, one in-flight observation, and one queued
// retry at most. The successful SDK publication listener is installed before
// callers can request work. Events during a failed observation are remembered;
// an event already consumed by a successful read cannot replay it. A deadline
// parks a burst, but never deletes the pending reason or starts overlapping SDK
// work. Later publication or an allowed wake/path event can make progress.
//
// This short lock owns bookkeeping only. SDK, storage, cancellation, scheduling
// and completion callbacks all run outside it. Retirement cannot interrupt a
// previously admitted SDK call; its completion cannot act for a newer ticket.
final class TunnelAuthRecoveryContinuation<Ticket: Equatable> {
    enum Phase: Equatable { case waiting, timeout }
    private struct Configuration {
        let enqueue: (@escaping () -> Void) -> Void
        let scheduleDeadline: (@escaping () -> Void) -> (() -> Void)
        let isCurrent: (Ticket) -> Bool
        let observe: (Ticket) throws -> Void
        let completed: (Ticket, TunnelDestinationRecoveryReason) -> Void
        let failed: (Ticket) -> Void
        let report: (Ticket, Phase) -> Void
    }
    private struct Pending {
        let generation: UInt64
        let ticket: Ticket
        var reasons: TunnelDestinationRecoveryReason
    }
    private let lock = NSLock()
    private var configuration: Configuration?
    private var pending: Pending?
    private var requestGeneration: UInt64 = 0
    private var stimulusGeneration: UInt64 = 0
    private var running = false
    private var queued = false
    private var deadlineGeneration: UInt64 = 0
    private var deadlineReported = false
    private var cancelDeadline: (() -> Void)?

    init(
        enqueue: @escaping (@escaping () -> Void) -> Void,
        scheduleDeadline: @escaping (@escaping () -> Void) -> (() -> Void),
        isCurrent: @escaping (Ticket) -> Bool,
        observe: @escaping (Ticket) throws -> Void,
        completed: @escaping (Ticket, TunnelDestinationRecoveryReason) -> Void,
        failed: @escaping (Ticket) -> Void,
        report: @escaping (Ticket, Phase) -> Void = { _, _ in }
    ) {
        configuration = Configuration(
            enqueue: enqueue, scheduleDeadline: scheduleDeadline, isCurrent: isCurrent,
            observe: observe, completed: completed, failed: failed, report: report
        )
    }

    // New allowed lifecycle work is a progress edge too. Repeated reasons for
    // one destination coalesce; a replacement destination retires the old one.
    func request(_ ticket: Ticket, reason: TunnelDestinationRecoveryReason) {
        guard !reason.isEmpty else { return }
        lock.lock()
        guard let configuration else { lock.unlock(); return }
        if pending?.ticket == ticket {
            pending?.reasons.formUnion(reason)
        } else {
            requestGeneration &+= 1
            pending = Pending(generation: requestGeneration, ticket: ticket, reasons: reason)
        }
        stimulusGeneration &+= 1
        let resume = !running && !queued
        if resume { queued = true }
        lock.unlock()
        if resume { configuration.enqueue { [weak self] in self?.runAttempt() } }
    }

    // The listener only records an edge and enqueues. It never observes auth,
    // rebuilds a consumer, resets transport or performs file I/O inline.
    func settled() {
        lock.lock()
        guard let configuration else { lock.unlock(); return }
        stimulusGeneration &+= 1
        let resume = pending != nil && !running && !queued
        if resume { queued = true }
        lock.unlock()
        if resume { configuration.enqueue { [weak self] in self?.runAttempt() } }
    }

    // A delayed old callback must not erase a newer current request. Check the
    // pending ticket itself outside this lock, then retire only that same
    // still-pending generation. No caller's obsolete ticket is authority here.
    func retireStalePending() {
        lock.lock()
        guard let configuration, let observed = pending else { lock.unlock(); return }
        lock.unlock()
        guard !configuration.isCurrent(observed.ticket) else { return }
        lock.lock()
        guard pending?.generation == observed.generation else { lock.unlock(); return }
        self.pending = nil
        deadlineGeneration &+= 1
        let cancel = cancelDeadline
        cancelDeadline = nil
        lock.unlock()
        cancel?()
    }

    func cancel() {
        lock.lock()
        let previous = configuration
        configuration = nil
        pending = nil
        deadlineGeneration &+= 1
        let cancel = cancelDeadline
        cancelDeadline = nil
        lock.unlock()
        cancel?()
        withExtendedLifetime(previous) {}
    }

    private func runAttempt() {
        lock.lock()
        queued = false
        guard !running, let configuration, let attempt = pending else { lock.unlock(); return }
        running = true
        let observedStimulus = stimulusGeneration
        deadlineGeneration &+= 1
        let deadline = deadlineGeneration
        deadlineReported = false
        let previousDeadline = cancelDeadline
        cancelDeadline = nil
        lock.unlock()
        previousDeadline?()

        let cancel = configuration.scheduleDeadline { [weak self] in
            self?.expire(deadline: deadline, request: attempt.generation)
        }
        lock.lock()
        let keepDeadline = self.configuration != nil && deadlineGeneration == deadline
        if keepDeadline { cancelDeadline = cancel }
        let admitted = self.configuration != nil && pending?.generation == attempt.generation
        lock.unlock()
        if !keepDeadline { cancel() }

        let result: Result<Void, Error>
        do {
            guard admitted, configuration.isCurrent(attempt.ticket) else {
                throw TunnelLocalAuthIdentityError.superseded
            }
            try configuration.observe(attempt.ticket)
            guard configuration.isCurrent(attempt.ticket) else {
                throw TunnelLocalAuthIdentityError.superseded
            }
            result = .success(())
        } catch { result = .failure(error) }
        let current = configuration.isCurrent(attempt.ticket)
        let unsettled: Bool
        if case .failure(let error) = result {
            unsettled = (error as NSError).localizedDescription == "auth snapshot was superseded or is not settled"
        } else { unsettled = false }

        lock.lock()
        running = false
        var resume = false
        var completed: TunnelDestinationRecoveryReason?
        var failed = false
        var waiting = false
        var deadlineToCancel: (() -> Void)?
        if self.configuration != nil, let latest = pending {
            if latest.generation != attempt.generation {
                resume = true
            } else if !current {
                pending = nil
            } else if unsettled {
                // Deadline expiry never consumes a later publication edge.
                resume = stimulusGeneration != observedStimulus
                waiting = true
            } else {
                pending = nil
                if case .success = result { completed = latest.reasons }
                else { failed = true }
            }
        }
        if pending == nil || resume {
            deadlineGeneration &+= 1
            deadlineToCancel = cancelDeadline
            cancelDeadline = nil
        }
        if resume { queued = true }
        lock.unlock()
        deadlineToCancel?()
        if let completed { configuration.completed(attempt.ticket, completed) }
        if failed { configuration.failed(attempt.ticket) }
        if waiting { configuration.report(attempt.ticket, .waiting) }
        if resume { configuration.enqueue { [weak self] in self?.runAttempt() } }
    }

    private func expire(deadline: UInt64, request: UInt64) {
        lock.lock()
        guard let configuration, let pending, pending.generation == request,
              deadlineGeneration == deadline, !deadlineReported else { lock.unlock(); return }
        deadlineReported = true
        let previousDeadline = cancelDeadline
        cancelDeadline = nil
        lock.unlock()
        // Only report the bounded wait. In-flight work still owns its slot,
        // and a pending reason remains eligible for a later real publication.
        configuration.report(pending.ticket, .timeout)
        withExtendedLifetime(previousDeadline) {}
    }
}
