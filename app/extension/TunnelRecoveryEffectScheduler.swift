import Foundation

// The input debounce coalesces path/settings notifications before auth reads.
// This separate single-slot phase spaces FINAL transport effects after those
// reads settle. A delayed auth result therefore cannot cancel a newer input
// timer, and a timer never repeats auth merely to wait out transport spacing.
//
// enqueue must be the same serial worker used by destination observation.
// Time is monotonic and checked on that worker immediately before perform,
// not when work was originally queued. No SDK/callback work occurs under the
// bookkeeping lock. Already-admitted effects cannot be preempted by retirement.
final class TunnelRecoveryEffectScheduler<Ticket: Equatable> {
    private struct Configuration {
        let enqueue: (@escaping () -> Void) -> Void
        let schedule: (TimeInterval, @escaping () -> Void) -> (() -> Void)
        let now: () -> TimeInterval
        let minimumInterval: TimeInterval
        let isCurrent: (Ticket) -> Bool
        let perform: (Ticket, TunnelDestinationRecoveryReason) -> Void
    }
    private struct Pending {
        let generation: UInt64
        let ticket: Ticket
        var reasons: TunnelDestinationRecoveryReason
    }
    private let lock = NSLock()
    private var configuration: Configuration?
    private var pending: Pending?
    private var generation: UInt64 = 0
    private var queued = false
    private var running = false
    private var timerGeneration: UInt64 = 0
    private var cancelTimer: (() -> Void)?
    private var lastTransportAdmission: TimeInterval?

    init(
        enqueue: @escaping (@escaping () -> Void) -> Void,
        schedule: @escaping (TimeInterval, @escaping () -> Void) -> (() -> Void),
        now: @escaping () -> TimeInterval, minimumInterval: TimeInterval,
        isCurrent: @escaping (Ticket) -> Bool,
        perform: @escaping (Ticket, TunnelDestinationRecoveryReason) -> Void
    ) {
        configuration = Configuration(
            enqueue: enqueue, schedule: schedule, now: now,
            minimumInterval: max(0, minimumInterval), isCurrent: isCurrent, perform: perform
        )
    }

    func submit(_ ticket: Ticket, reasons: TunnelDestinationRecoveryReason) {
        lock.lock()
        let configuration = self.configuration
        lock.unlock()
        configuration?.enqueue { [weak self] in self?.acceptOnQueue(ticket, reasons: reasons) }
    }

    // All submissions are serialized before their current-origin check. An
    // old completion cannot replace a new slot while this check is in flight.
    private func acceptOnQueue(_ ticket: Ticket, reasons: TunnelDestinationRecoveryReason) {
        lock.lock()
        let configuration = self.configuration
        lock.unlock()
        guard !reasons.isEmpty, let configuration, configuration.isCurrent(ticket) else { return }
        lock.lock()
        guard self.configuration != nil else { lock.unlock(); return }
        if pending?.ticket == ticket { pending?.reasons.formUnion(reasons) }
        else {
            generation &+= 1
            pending = Pending(generation: generation, ticket: ticket, reasons: reasons)
        }
        timerGeneration &+= 1
        let cancel = cancelTimer
        cancelTimer = nil
        let resume = !queued && !running
        if resume { queued = true }
        lock.unlock()
        cancel?()
        if resume { configuration.enqueue { [weak self] in self?.runOnQueue() } }
    }

    func retireStalePending() {
        lock.lock()
        guard let configuration, let observed = pending else { lock.unlock(); return }
        lock.unlock()
        guard !configuration.isCurrent(observed.ticket) else { return }
        lock.lock()
        guard pending?.generation == observed.generation else { lock.unlock(); return }
        pending = nil
        timerGeneration &+= 1
        let cancel = cancelTimer
        cancelTimer = nil
        lock.unlock()
        cancel?()
    }

    func cancel() {
        lock.lock()
        let previous = configuration
        configuration = nil
        pending = nil
        timerGeneration &+= 1
        let cancel = cancelTimer
        cancelTimer = nil
        lock.unlock()
        cancel?()
        withExtendedLifetime(previous) {}
    }

    private func runOnQueue() {
        lock.lock()
        queued = false
        guard !running, let configuration, let observed = pending else { lock.unlock(); return }
        lock.unlock()
        guard configuration.isCurrent(observed.ticket) else { retireStalePending(); return }
        let now = configuration.now()
        lock.lock()
        guard self.configuration != nil, let pending,
              pending.generation == observed.generation else { lock.unlock(); return }
        let remaining = pending.reasons.contains(.path)
            ? lastTransportAdmission.map { max(0, $0 + configuration.minimumInterval - now) } ?? 0
            : 0
        if remaining > 0 {
            timerGeneration &+= 1
            let timer = timerGeneration
            let previousTimer = cancelTimer
            cancelTimer = nil
            lock.unlock()
            previousTimer?()
            let cancel = configuration.schedule(remaining) { [weak self] in self?.timerFired(timer) }
            lock.lock()
            let keep = self.configuration != nil && timerGeneration == timer
            if keep { cancelTimer = cancel }
            lock.unlock()
            if !keep { cancel() }
            return
        }
        self.pending = nil
        running = true
        timerGeneration &+= 1
        let previousTimer = cancelTimer
        cancelTimer = nil
        if pending.reasons.contains(.path) { lastTransportAdmission = now }
        lock.unlock()
        previousTimer?()
        configuration.perform(pending.ticket, pending.reasons)
        lock.lock()
        running = false
        let resume = self.configuration != nil && self.pending != nil && !queued
        if resume { queued = true }
        lock.unlock()
        if resume { configuration.enqueue { [weak self] in self?.runOnQueue() } }
    }

    private func timerFired(_ generation: UInt64) {
        lock.lock()
        guard let configuration, pending != nil, timerGeneration == generation else { lock.unlock(); return }
        timerGeneration &+= 1
        let previousTimer = cancelTimer
        cancelTimer = nil
        let resume = !queued && !running
        if resume { queued = true }
        lock.unlock()
        withExtendedLifetime(previousTimer) {}
        if resume { configuration.enqueue { [weak self] in self?.runOnQueue() } }
    }
}
