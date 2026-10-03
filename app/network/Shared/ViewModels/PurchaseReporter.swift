//
//  PurchaseReporter.swift
//  URnetwork
//

// The App Store's transaction stream: not part of the direct-download build,
// which bills through Stripe and does not link StoreKit (see BillingDistribution).
#if !DIRECT_DOWNLOAD
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
 * The proof of one current entitlement (a verified, unrevoked transaction from
 * `Transaction.currentEntitlements`), for the report-only pass. It carries no
 * Transaction handle on purpose: the report-only pass never finishes.
 */
struct EntitlementProof {
    let transactionId: UInt64
    let appAccountToken: UUID?
    let jws: String
}

/**
 * The result of one entitlement scan. `foundCurrent`/`foundOther` classify
 * the entitlements by network (the restore outcome); `newlyCredited` is set
 * when the server credited a report-only proof just now, i.e. a purchase that
 * had been stranded (start the confirmation poll).
 */
struct EntitlementScanResult {
    var foundCurrent = false
    var foundOther = false
    var newlyCredited = false
    var reportResults: [UInt64: PurchaseReportOutcome] = [:]
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
     * Transaction ids of current entitlements whose report-only pass already
     * reached a terminal answer, so the launch scan reports each entitlement
     * once rather than on every launch (the verify endpoint is rate limited
     * per account). A restore pass reports regardless.
     */
    private static let reportedEntitlementsKey = "ur.reportedEntitlementTransactionIds"

    /// Bounds the reported-entitlement record (one id per renewal period).
    private static let maxReportedEntitlements = 64

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

    /// One report attempt of a transaction JWS against the verify endpoint.
    typealias Verify = @MainActor (_ jws: String) async -> ReportAttemptResult

    /**
     * Returns the verify call for the current session, or nil when no session
     * exists. Reporting requires a session (the verify endpoint is
     * session-authed); an api whose byJwt is empty is "no session".
     */
    private var verifyProvider: (@MainActor () -> Verify?)?

    private let defaults: UserDefaults
    private let sleepMillis: @MainActor (Int64) async -> Void

    private var inFlight: Set<UInt64> = []
    // report-only passes keep their own set, so a scan never makes the
    // report-then-finish path answer alreadyInFlight (and skip its finish)
    private var entitlementInFlight: Set<UInt64> = []

    private var pending: [UInt64: PendingPurchaseReport]
    private var reportedEntitlements: [UInt64]

    private convenience init() {
        self.init(defaults: .standard, sleepMillis: { millis in
            try? await Task.sleep(nanoseconds: UInt64(millis) * 1_000_000)
        })
    }

    /// Tests inject their own defaults suite and an instant sleep.
    init(defaults: UserDefaults, sleepMillis: @escaping @MainActor (Int64) async -> Void) {
        self.defaults = defaults
        self.sleepMillis = sleepMillis
        pending = Self.loadPersisted(defaults: defaults)
        reportedEntitlements = defaults.array(forKey: Self.reportedEntitlementsKey)?
            .compactMap { ($0 as? NSNumber)?.uint64Value } ?? []
    }

    func configure(apiProvider: @escaping @MainActor () -> SdkApi?) {
        configure(verifyProvider: {
            guard let api = apiProvider(), !api.getByJwt().isEmpty else {
                return nil
            }
            return { jws in await Self.reportOnce(api: api, jws: jws) }
        })
    }

    func configure(verifyProvider: @escaping @MainActor () -> Verify?) {
        self.verifyProvider = verifyProvider
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

    // MARK: report-only (current entitlements)

    /**
     * Report-only for current entitlements: report every verified entitlement
     * purchased under `networkId` (appAccountToken matches) and never finish
     * anything.
     *
     * The report-then-finish contract above only covers transactions StoreKit
     * still redelivers. A transaction finished before any server contact (the
     * pre-reorder builds), whose first webhook was lost, is never redelivered
     * and the reconciler cannot see it either, so its only remaining proof is
     * the entitlement StoreKit keeps listing. Reporting that proof lets the
     * server credit it. An entitlement is usually already finished, so there is
     * nothing to finish; one that is still unfinished stays owned by
     * `reportAndFinish` through redelivery.
     *
     * Entitlements under another network (or without a token) are not
     * reported: the server could only answer wrong_network or invalid, and
     * the linked network is credited via its own session.
     *
     * Each entitlement is reported once (see `reportedEntitlementsKey`) unless
     * `force` is set, which a user-triggered restore uses.
     */
    func reportEntitlements(
        _ entitlements: [EntitlementProof],
        networkId: UUID?,
        force: Bool
    ) async -> EntitlementScanResult {
        var scan = EntitlementScanResult()
        var noSession = false
        for entitlement in entitlements {
            guard let networkId, entitlement.appAccountToken == networkId else {
                scan.foundOther = true
                continue
            }
            scan.foundCurrent = true

            let transactionId = entitlement.transactionId
            if noSession || (!force && reportedEntitlements.contains(transactionId)) {
                continue
            }
            guard !entitlementInFlight.contains(transactionId) else {
                continue
            }
            entitlementInFlight.insert(transactionId)
            defer { entitlementInFlight.remove(transactionId) }

            let result = await reportUntilTerminalResult(
                transactionId: transactionId,
                jws: entitlement.jws
            )
            scan.reportResults[transactionId] = result.outcome
            switch result {
            case .credited:
                scan.newlyCredited = true
                recordReportedEntitlement(transactionId)
            case .alreadyCredited, .wrongNetwork, .invalid:
                recordReportedEntitlement(transactionId)
            case .deferredNoSession:
                // no session for this one means no session for the rest; keep
                // classifying, and the next scan reports them
                noSession = true
            case .transientFailure:
                // not recorded: the next scan reports it again
                break
            }
        }
        return scan
    }

    private func recordReportedEntitlement(_ transactionId: UInt64) {
        guard !reportedEntitlements.contains(transactionId) else {
            return
        }
        reportedEntitlements.append(transactionId)
        if Self.maxReportedEntitlements < reportedEntitlements.count {
            reportedEntitlements.removeFirst(reportedEntitlements.count - Self.maxReportedEntitlements)
        }
        defaults.set(
            reportedEntitlements.map { NSNumber(value: $0) },
            forKey: Self.reportedEntitlementsKey
        )
    }

    // MARK: report loop

    enum ReportAttemptResult {
        case status(String)
        case transportFailure
    }

    /// A terminal server answer, or why the pass stopped short of one.
    private enum ReportResult {
        case credited
        case alreadyCredited
        case wrongNetwork
        case invalid
        case deferredNoSession
        case transientFailure

        var outcome: PurchaseReportOutcome {
            switch self {
            case .credited, .alreadyCredited: return .credited
            case .wrongNetwork: return .wrongNetwork
            case .invalid: return .invalid
            case .deferredNoSession: return .deferredNoSession
            case .transientFailure: return .transientFailure
            }
        }
    }

    private func reportUntilTerminal(
        transactionId: UInt64,
        jws: String
    ) async -> PurchaseReportOutcome {
        return await reportUntilTerminalResult(transactionId: transactionId, jws: jws).outcome
    }

    private func reportUntilTerminalResult(
        transactionId: UInt64,
        jws: String
    ) async -> ReportResult {
        var attempt = 0
        while true {
            guard let verify = verifyProvider?() else {
                // the verify endpoint is session-authed; without a session the
                // report can only fail. Keep the proof and wait for
                // retryDeferredReports / the next launch.
                return .deferredNoSession
            }

            let result = await verify(jws)

            switch result {
            case .status(let status) where SdkIsPurchaseReportTerminal(status):
                switch status {
                case SdkPurchaseReportStatusCredited:
                    return .credited
                case SdkPurchaseReportStatusAlreadyCredited:
                    return .alreadyCredited
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
                await sleepMillis(backoffMillis)
            }
        }
    }

    private static func reportOnce(api: SdkApi, jws: String) async -> ReportAttemptResult {
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
            defaults.set(data, forKey: Self.pendingReportsKey)
        } catch {
            print("[PurchaseReporter] failed to persist pending reports: \(error)")
        }
    }

    private static func loadPersisted(defaults: UserDefaults) -> [UInt64: PendingPurchaseReport] {
        guard let data = defaults.data(forKey: pendingReportsKey) else {
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

#endif
