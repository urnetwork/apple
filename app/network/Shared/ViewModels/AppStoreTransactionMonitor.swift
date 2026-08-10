//
//  AppStoreTransactionMonitor.swift
//  URnetwork
//

import Foundation
import StoreKit
import URnetworkSdk

/**
 * Process-scoped StoreKit transaction listener.
 *
 * `Transaction.updates` used to be consumed by `AppStoreSubscriptionManager`,
 * which is created with `MainView` — i.e. only after a successful login. Any
 * transaction StoreKit delivered while the app sat on the login screen (an Ask
 * to Buy approval, a renewal, a purchase finished on another device) had no
 * listener and was simply redelivered forever, never finished and never acted
 * on. Apple's guidance is to start this listener as close to process launch as
 * possible, so it lives here as a singleton started from `NetworkApp.init`.
 *
 * The monitor owns the report-then-finish sequence (finding A1): every
 * delivery path — `Transaction.updates`, the launch sweep of
 * `Transaction.unfinished`, the direct `purchase()` result, and
 * `restorePurchases()` — funnels through `process`, which runs
 * `PurchaseReporter`'s persist → report → finish → clear contract. A
 * transaction is only ever finished after the server has answered a terminal
 * status for its JWS; until then StoreKit keeps redelivering it, which is the
 * built-in crash recovery.
 *
 * The monitor is deliberately account-agnostic: it reports whatever session
 * exists (the JWS carries its own appAccountToken) and records which token the
 * transaction carried. The PER-NETWORK decision — "should this transaction
 * start the confirmation poll for the currently logged-in network?" — stays in
 * `AppStoreSubscriptionManager`, which compares the token against its own
 * networkId. A transaction for network A must not spin network B's poll — and
 * the server enforces the same boundary: `credited` is only answered when the
 * session network matches the token, so the sequence below can only fire for
 * the network that owns the purchase.
 */
@MainActor
final class AppStoreTransactionMonitor: ObservableObject {

    static let shared = AppStoreTransactionMonitor()

    /**
     * Bumped for every transaction the server confirmed as credited (or
     * already credited) for the CURRENT session's network — from
     * `Transaction.updates`, the launch sweep, or a direct purchase. This
     * replaces the old optimistic "verified locally, assume the webhook will
     * land" bump: the confirmation poll now starts from a server
     * acknowledgment, not hope. A published counter cannot be nil and cannot
     * be forgotten the way an optional callback can; consumers observe it and
     * read `lastTransactionAppAccountToken` for the gating decision.
     */
    @Published private(set) var transactionSequence: Int = 0

    /**
     * Bumped when a delivered transaction reported `wrong_network`: it is
     * real and was finished (the linked network gets its credit via the
     * webhook/reconciler), but it belongs to a different network than the
     * session. Consumers surface "purchased under a different account".
     */
    @Published private(set) var wrongNetworkSequence: Int = 0

    /**
     * The appAccountToken of the most recent credited transaction: the
     * networkId the purchase was made under (see `purchase()` in
     * `AppStoreSubscriptionManager`, which sets it). nil when the transaction
     * carried no token.
     */
    private(set) var lastTransactionAppAccountToken: UUID?

    /**
     * Transactions whose report could not reach a terminal status yet —
     * deferred for lack of a session, or out of in-session retries. Kept (with
     * their JWS) so `retryDeferredReports` can re-run the sequence the moment
     * a session exists, without waiting for StoreKit's next redelivery. The
     * JWS is also persisted durably by the reporter, so nothing here is
     * load-bearing across a crash.
     */
    private var unreported: [UInt64: (transaction: Transaction, jws: String)] = [:]

    private var updatesTask: Task<Void, Never>?
    private var started = false

    /**
     * Idempotent. Called once from `NetworkApp.init` (process launch).
     * `apiProvider` returns whatever session api the app currently has (nil,
     * or an api with an empty byJwt, means logged out — reporting defers).
     */
    func start(apiProvider: @escaping @MainActor () -> SdkApi?) {
        guard !started else {
            return
        }
        started = true

        PurchaseReporter.shared.configure(apiProvider: apiProvider)

        // the long-lived listener: everything StoreKit delivers from here on
        updatesTask = Task { [weak self] in
            for await result in Transaction.updates {
                guard let self else {
                    break
                }
                await self.handle(result)
            }
        }

        // the launch sweep: transactions that completed while NO listener was
        // running (app closed, or killed before finish()). Unfinished
        // transactions are redelivered by StoreKit until finished — which now
        // includes every transaction whose report never reached a terminal
        // status. Sweeping them here retries the report and un-strands
        // purchases that would otherwise wait for a login that may never come.
        Task { [weak self] in
            for await result in Transaction.unfinished {
                guard let self else {
                    break
                }
                await self.handle(result)
            }

            // belt-and-braces on top of the redelivery: re-report any
            // persisted proof with no live transaction behind it (e.g. the
            // crash landed between finish() and the persisted clear)
            await PurchaseReporter.shared.retryPersistedReports()
        }
    }

    /**
     * A session now exists (or a new one replaced the old): re-run the
     * report-then-finish sequence for anything still waiting on a server
     * answer. Called from `AppStoreSubscriptionManager.init` (post-login).
     */
    func retryDeferredReports() {
        let retries = unreported
        unreported.removeAll()

        Task { [weak self] in
            for (_, entry) in retries {
                _ = await self?.process(transaction: entry.transaction, jws: entry.jws)
            }
            await PurchaseReporter.shared.retryPersistedReports()
        }
    }

    private func handle(_ result: VerificationResult<Transaction>) async {
        switch result {
        case .verified(let transaction):
            _ = await process(transaction: transaction, jws: result.jwsRepresentation)
        case .unverified(_, let error):
            print("[AppStoreTransactionMonitor] unverified transaction: \(error.localizedDescription)")
        }
    }

    /**
     * The single report-then-finish sequence (see the class comment). Returns
     * the outcome so direct callers (`purchase()`, `restorePurchases()`) can
     * shape their UI; observers get the same signal through
     * `transactionSequence` / `wrongNetworkSequence`.
     */
    func process(transaction: Transaction, jws: String) async -> PurchaseReportOutcome {
        guard transaction.revocationDate == nil else {
            // revoked: nothing creditable to report. Finishing without server
            // contact is safe here — revocation is already server-visible
            // through the webhook/reconciler paths.
            await transaction.finish()
            return .invalid
        }

        let outcome = await PurchaseReporter.shared.reportAndFinish(
            transaction: transaction,
            jws: jws
        )

        switch outcome {
        case .credited:
            unreported.removeValue(forKey: transaction.id)
            lastTransactionAppAccountToken = transaction.appAccountToken
            transactionSequence += 1
        case .wrongNetwork:
            unreported.removeValue(forKey: transaction.id)
            wrongNetworkSequence += 1
        case .invalid:
            unreported.removeValue(forKey: transaction.id)
            print("[AppStoreTransactionMonitor] server rejected transaction \(transaction.id) as invalid")
        case .deferredNoSession, .transientFailure:
            // keep the live handle so a session appearing retries immediately;
            // the durable JWS + StoreKit redelivery cover every other path
            unreported[transaction.id] = (transaction, jws)
        case .alreadyInFlight:
            break
        }

        return outcome
    }
}
