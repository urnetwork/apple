//
//  PurchaseReporter.swift
//  URnetwork
//

import Foundation
import StoreKit
import URnetworkSdk

/**
 * The outcome of one report-then-finish pass over a verified transaction.
 * Only the first three are terminal server answers; the rest leave the
 * transaction UNFINISHED (StoreKit keeps redelivering it — the built-in
 * crash/retry recovery) with the JWS persisted on top as belt-and-braces.
 */
enum PurchaseReportOutcome {
    /**
     * `credited` or `already_credited`: the server has (or already had) the
     * credit for THIS session's network. The transaction was finished and the
     * persisted proof dropped. This is the signal to start the confirmation
     * poll.
     */
    case credited
    /**
     * Terminal: the proof verified but the purchase is linked to a DIFFERENT
     * network. The transaction was finished (it is real, and the linked
     * network gets its credit via webhook/reconciler) — surface "purchased
     * under a different account".
     */
    case wrongNetwork
    /**
     * Terminal: the server says the proof will never verify. The transaction
     * was finished so StoreKit stops redelivering it.
     */
    case invalid
    /**
     * No session api exists yet (logged out, or the network space is still
     * initializing). The JWS is persisted, the transaction is NOT finished,
     * and reporting is deferred until a session exists
     * (`AppStoreTransactionMonitor.retryDeferredReports`).
     */
    case deferredNoSession
    /**
     * Transport failure (or a non-terminal `pending` answer) survived the
     * bounded in-session retries. The JWS stays persisted and the transaction
     * stays unfinished; the next launch (or restore pass, or login) retries.
     */
    case transientFailure
    /**
     * Another path is reporting this same transaction right now (e.g. the
     * launch sweep raced a restore pass). No-op for this caller; the in-flight
     * pass owns finishing.
     */
    case alreadyInFlight
}

/**
 * Report-then-finish for StoreKit transactions (finding A1 in
 * server/UPGRADE.md §3), implementing the client contract documented in
 * sdk/purchase_report.go:
 *
 *  1. PERSIST the transaction JWS durably the moment a verified transaction
 *     arrives, BEFORE anything else.
 *  2. REPORT it via Api.VerifyAppleTransaction, retrying on transport failure
 *     with PurchaseReportBackoffMillis (bounded in-session; the store's
 *     redelivery of unfinished transactions makes cross-session retry free).
 *  3. Only after a TERMINAL status (credited / already_credited /
 *     wrong_network / invalid) call Transaction.finish() and drop the
 *     persisted proof. NEVER finish before a terminal status: a finished
 *     transaction is never redelivered, so an unreported finish is exactly
 *     the "lost webhook = money gone" dead end this exists to close.
 *
 * The report is deliberately made with whatever session api exists,
 * regardless of which network is logged in: the JWS carries its own
 * appAccountToken, and a cross-account report simply answers wrong_network
 * (the linked network is credited via the webhook/reconciler paths).
 */
@MainActor
final class PurchaseReporter {

    static let shared = PurchaseReporter()

    /**
     * How many report attempts one pass makes before giving up in-session.
     * With the sdk backoff schedule (1s, 5s, ...) three attempts cost at most
     * ~6s of waiting — acceptable inside a purchase or restore spinner. The
     * uncapped retry the sdk contract describes comes from redelivery: every
     * launch sweep / restore pass / login runs a fresh bounded pass.
     */
    private static let maxAttemptsPerPass = 3

    private static let pendingReportsKey = "ur.pendingPurchaseReports"

    /**
     * The durable record: everything needed to re-report after a crash, even
     * if StoreKit's own redelivery is delayed or the transaction was finished
     * but the clear was lost.
     */
    private struct PendingPurchaseReport: Codable {
        let transactionId: UInt64
        let jws: String
        var attemptCount: Int
        let firstSeen: Date
    }

    /**
     * Returns the session api, or nil when none exists. Reporting requires a
     * session (the verify endpoint is session-authed); an api whose byJwt is
     * empty is "no session".
     */
    private var apiProvider: (@MainActor () -> SdkApi?)?

    private var inFlight: Set<UInt64> = []

    private var pending: [UInt64: PendingPurchaseReport]

    private init() {
        pending = Self.loadPersisted()
    }

    func configure(apiProvider: @escaping @MainActor () -> SdkApi?) {
        self.apiProvider = apiProvider
    }

    /**
     * The full contract for one delivered transaction: persist → report until
     * terminal (bounded in-session) → finish → clear. Every delivery path
     * (Transaction.updates, the launch sweep of Transaction.unfinished, the
     * direct purchase() result, restorePurchases) funnels here via
     * `AppStoreTransactionMonitor.process`.
     */
    func reportAndFinish(transaction: Transaction, jws: String) async -> PurchaseReportOutcome {
        let transactionId = transaction.id

        // 1. persist BEFORE anything else, so process death loses nothing
        persist(transactionId: transactionId, jws: jws)

        guard !inFlight.contains(transactionId) else {
            return .alreadyInFlight
        }
        inFlight.insert(transactionId)
        defer { inFlight.remove(transactionId) }

        // 2. report until terminal
        let reportOutcome = await reportUntilTerminal(transactionId: transactionId, jws: jws)

        switch reportOutcome {
        case .credited, .wrongNetwork, .invalid:
            // 3. only THEN finish and drop the proof
            await transaction.finish()
            clearPersisted(transactionId: transactionId)
        case .deferredNoSession, .transientFailure, .alreadyInFlight:
            // NOT finished: StoreKit keeps redelivering (crash recovery), and
            // the persisted JWS keeps the report retryable even without a
            // redelivery.
            break
        }

        return reportOutcome
    }

    /**
     * Crash recovery for the persisted half: re-report any proof that never
     * reached a terminal status. There is no Transaction handle here, so this
     * only reports and clears — finishing is owned by StoreKit's redelivery of
     * the (still unfinished) transaction through the monitor, which will get a
     * fast `already_credited` and finish. This also cleans up the
     * finished-but-clear-lost crash window: the re-report answers terminal and
     * the entry is dropped.
     *
     * Called from the monitor at launch and whenever a session appears.
     */
    func retryPersistedReports() async {
        for report in pending.values {
            guard !inFlight.contains(report.transactionId) else {
                continue
            }
            inFlight.insert(report.transactionId)
            defer { inFlight.remove(report.transactionId) }

            let outcome = await reportUntilTerminal(
                transactionId: report.transactionId,
                jws: report.jws
            )
            switch outcome {
            case .credited, .wrongNetwork, .invalid:
                clearPersisted(transactionId: report.transactionId)
            case .deferredNoSession:
                // no session for this one means no session for the rest
                return
            case .transientFailure, .alreadyInFlight:
                break
            }
        }
    }

    // MARK: report loop

    private enum ReportAttemptResult {
        case status(String)
        case transportFailure
    }

    private func reportUntilTerminal(
        transactionId: UInt64,
        jws: String
    ) async -> PurchaseReportOutcome {
        var attempt = 0
        while true {
            guard let api = apiProvider?(), !api.getByJwt().isEmpty else {
                // the verify endpoint is session-authed; without a session the
                // report can only fail. Keep the proof and wait for
                // retryDeferredReports / the next launch.
                return .deferredNoSession
            }

            let result = await reportOnce(api: api, jws: jws)

            switch result {
            case .status(let status) where SdkIsPurchaseReportTerminal(status):
                switch status {
                case SdkPurchaseReportStatusCredited, SdkPurchaseReportStatusAlreadyCredited:
                    return .credited
                case SdkPurchaseReportStatusWrongNetwork:
                    return .wrongNetwork
                default:
                    return .invalid
                }
            case .status, .transportFailure:
                // transport failure or `pending`: not terminal, retry with the
                // sdk backoff schedule — bounded per pass, unbounded across
                // passes (redelivery)
                attempt += 1
                incrementPersistedAttempt(transactionId: transactionId)
                if Self.maxAttemptsPerPass <= attempt {
                    return .transientFailure
                }
                let backoffMillis = SdkPurchaseReportBackoffMillis(Int32(attempt - 1))
                try? await Task.sleep(nanoseconds: UInt64(backoffMillis) * 1_000_000)
            }
        }
    }

    private func reportOnce(api: SdkApi, jws: String) async -> ReportAttemptResult {
        let args = SdkVerifyAppleTransactionArgs()
        args.signedTransaction = jws

        return await withCheckedContinuation { continuation in
            let callback = VerifyAppleTransactionCallback { result, err in
                if err != nil {
                    continuation.resume(returning: .transportFailure)
                    return
                }
                guard let status = result?.status, !status.isEmpty else {
                    continuation.resume(returning: .transportFailure)
                    return
                }
                continuation.resume(returning: .status(status))
            }
            api.verifyAppleTransaction(args, callback: callback)
        }
    }

    // MARK: persistence (UserDefaults, keyed by transaction id)

    private func persist(transactionId: UInt64, jws: String) {
        if let existing = pending[transactionId], existing.jws == jws {
            // already persisted (a redelivery); keep the original record
            return
        }
        pending[transactionId] = PendingPurchaseReport(
            transactionId: transactionId,
            jws: jws,
            attemptCount: 0,
            firstSeen: Date()
        )
        save()
    }

    private func clearPersisted(transactionId: UInt64) {
        guard pending.removeValue(forKey: transactionId) != nil else {
            return
        }
        save()
    }

    private func incrementPersistedAttempt(transactionId: UInt64) {
        guard var report = pending[transactionId] else {
            return
        }
        report.attemptCount += 1
        pending[transactionId] = report
        save()
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(Array(pending.values))
            UserDefaults.standard.set(data, forKey: Self.pendingReportsKey)
        } catch {
            print("[PurchaseReporter] failed to persist pending reports: \(error)")
        }
    }

    private static func loadPersisted() -> [UInt64: PendingPurchaseReport] {
        guard let data = UserDefaults.standard.data(forKey: pendingReportsKey) else {
            return [:]
        }
        do {
            let reports = try JSONDecoder().decode([PendingPurchaseReport].self, from: data)
            return Dictionary(uniqueKeysWithValues: reports.map { ($0.transactionId, $0) })
        } catch {
            print("[PurchaseReporter] failed to load pending reports: \(error)")
            return [:]
        }
    }
}

private class VerifyAppleTransactionCallback: SdkCallback<
    SdkVerifyStorePurchaseResult, SdkVerifyAppleTransactionCallbackProtocol
>, SdkVerifyAppleTransactionCallbackProtocol
{
    func result(_ result: SdkVerifyStorePurchaseResult?, err: Error?) {
        handleResult(result, err: err)
    }
}
