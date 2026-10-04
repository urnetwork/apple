// StoreKit reporting is not part of the direct-download build
#if !DIRECT_DOWNLOAD
import Foundation
import Testing
import URnetworkSdk
@testable import URnetwork

/**
 * PurchaseReporter (finding A1 in server/UPGRADE.md §3): the report-only pass
 * over current entitlements, and the persisted-proof retry. The verify call is
 * a fake that answers from a script, the backoff sleep is instant and the
 * defaults are a fresh suite per test, so nothing here touches the network,
 * StoreKit or a clock.
 */
@MainActor
struct PurchaseReporterTests {

    private let networkId = UUID(uuidString: "00000000-0000-0000-0000-00000000000a")!
    private let otherNetworkId = UUID(uuidString: "00000000-0000-0000-0000-00000000000b")!

    /// The verify endpoint: records each JWS and answers from `answers` (by JWS), credited by default.
    @MainActor
    private final class FakeVerify {
        var calls: [String] = []
        var answers: [String: PurchaseReporter.ReportAttemptResult] = [:]
        var hasSession = true

        func provider() -> PurchaseReporter.Verify? {
            guard hasSession else {
                return nil
            }
            return { [self] jws in
                calls.append(jws)
                return answers[jws] ?? .status(SdkPurchaseReportStatusCredited)
            }
        }
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "PurchaseReporterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeReporter(defaults: UserDefaults, verify: FakeVerify) -> PurchaseReporter {
        let reporter = PurchaseReporter(defaults: defaults, sleepMillis: { _ in })
        reporter.configure(verifyProvider: { verify.provider() })
        return reporter
    }

    private func proof(_ transactionId: UInt64, _ token: UUID?) -> EntitlementProof {
        EntitlementProof(transactionId: transactionId, appAccountToken: token, jws: "jws-\(transactionId)")
    }

    // MARK: report-only entitlements

    @Test func reportsEveryEntitlementPurchasedUnderTheNetwork() async {
        let verify = FakeVerify()
        let reporter = makeReporter(defaults: makeDefaults(), verify: verify)

        let scan = await reporter.reportEntitlements(
            [proof(1, networkId), proof(2, otherNetworkId), proof(3, nil), proof(4, networkId)],
            networkId: networkId,
            force: false
        )

        // a transaction finished before any server contact is only reachable
        // through its entitlement: it must be reported. The entitlement
        // without a token (an offer-code redemption) is reported too; only
        // another network's is not.
        #expect(verify.calls == ["jws-1", "jws-3", "jws-4"])
        #expect(scan.foundCurrent)
        #expect(scan.foundOther)
        #expect(scan.reportResults[1] == .credited)
        #expect(scan.reportResults[4] == .credited)
    }

    // MARK: offer-code redemptions (no appAccountToken)

    /**
     * UPGRADE.md A1: an offer code redeemed through the App Store redeem
     * sheet or link carries no appAccountToken. Builds before the server
     * binding finished it on `invalid`, so its entitlement is the only proof
     * left: the scan must report it with the signed-in session so the server
     * can bind it to the network that was issued the code.
     */
    @Test func anOfferCodeRedemptionWithoutATokenIsReportedAndCountsWhenCredited() async {
        let verify = FakeVerify()
        let reporter = makeReporter(defaults: makeDefaults(), verify: verify)

        let scan = await reporter.reportEntitlements([proof(7, nil)], networkId: networkId, force: true)

        #expect(verify.calls == ["jws-7"])
        #expect(scan.reportResults[7] == .credited)
        #expect(scan.newlyCredited)
        #expect(scan.foundCurrent)
        #expect(!scan.foundOther)
    }

    @Test func anOfferCodeRedemptionTheServerRefusesIsNotThisNetworks() async {
        let verify = FakeVerify()
        verify.answers["jws-7"] = .status(SdkPurchaseReportStatusInvalid)
        let reporter = makeReporter(defaults: makeDefaults(), verify: verify)

        let scan = await reporter.reportEntitlements([proof(7, nil)], networkId: networkId, force: true)

        #expect(verify.calls == ["jws-7"])
        #expect(scan.reportResults[7] == .invalid)
        #expect(!scan.newlyCredited)
        #expect(!scan.foundCurrent)
        #expect(scan.foundOther)

        // terminal: the launch scan does not report it again
        _ = await reporter.reportEntitlements([proof(7, nil)], networkId: networkId, force: false)
        #expect(verify.calls == ["jws-7"])
    }

    /**
     * A credited transaction without a token was credited to the session
     * network the report was made with, so that network's confirmation poll
     * (and the redeem flow's success callback) must start.
     */
    @Test func aCreditedOfferCodeRedemptionIsCreditedToTheSessionNetwork() {
        #expect(PurchaseReporter.creditedNetworkId(appAccountToken: nil, sessionBefore: networkId, sessionAfter: networkId) == networkId)
        // a token always names the network
        #expect(PurchaseReporter.creditedNetworkId(appAccountToken: otherNetworkId, sessionBefore: networkId, sessionAfter: networkId) == otherNetworkId)
        // the session changed (or was gone) during the report: unknown
        #expect(PurchaseReporter.creditedNetworkId(appAccountToken: nil, sessionBefore: networkId, sessionAfter: otherNetworkId) == nil)
        #expect(PurchaseReporter.creditedNetworkId(appAccountToken: nil, sessionBefore: nil, sessionAfter: nil) == nil)
    }

    @Test func aStrandedPurchaseCreditedNowIsNewlyCredited() async {
        let verify = FakeVerify()
        verify.answers["jws-1"] = .status(SdkPurchaseReportStatusAlreadyCredited)
        let reporter = makeReporter(defaults: makeDefaults(), verify: verify)

        let alreadyCredited = await reporter.reportEntitlements([proof(1, networkId)], networkId: networkId, force: false)
        #expect(verify.calls == ["jws-1"])
        #expect(!alreadyCredited.newlyCredited)

        let credited = await reporter.reportEntitlements([proof(2, networkId)], networkId: networkId, force: false)
        #expect(verify.calls == ["jws-1", "jws-2"])
        #expect(credited.newlyCredited)
    }

    @Test func reportOnlyNeverEntersTheReportThenFinishRecord() async {
        let defaults = makeDefaults()
        let verify = FakeVerify()
        verify.answers["jws-1"] = .transportFailure
        let reporter = makeReporter(defaults: defaults, verify: verify)

        _ = await reporter.reportEntitlements([proof(1, networkId)], networkId: networkId, force: false)

        // the entitlement has no Transaction handle to finish, and its proof
        // is not added to the persisted report-then-finish queue either
        #expect(defaults.data(forKey: "ur.pendingPurchaseReports") == nil)
    }

    @Test func theLaunchScanReportsEachEntitlementOnceAndRestoreAlways() async {
        let defaults = makeDefaults()
        let verify = FakeVerify()
        let reporter = makeReporter(defaults: defaults, verify: verify)

        _ = await reporter.reportEntitlements([proof(1, networkId)], networkId: networkId, force: false)
        _ = await reporter.reportEntitlements([proof(1, networkId)], networkId: networkId, force: false)
        #expect(verify.calls == ["jws-1"])

        // the record survives a relaunch
        let relaunched = makeReporter(defaults: defaults, verify: verify)
        _ = await relaunched.reportEntitlements([proof(1, networkId)], networkId: networkId, force: false)
        #expect(verify.calls == ["jws-1"])

        // a user-triggered restore reports again
        let restore = await relaunched.reportEntitlements([proof(1, networkId)], networkId: networkId, force: true)
        #expect(verify.calls == ["jws-1", "jws-1"])
        #expect(restore.foundCurrent)
    }

    @Test func aTransientFailureIsReportedAgainOnTheNextScan() async {
        let verify = FakeVerify()
        verify.answers["jws-1"] = .transportFailure
        let reporter = makeReporter(defaults: makeDefaults(), verify: verify)

        let failed = await reporter.reportEntitlements([proof(1, networkId)], networkId: networkId, force: false)
        // bounded in-session retries (3 attempts)
        #expect(verify.calls == ["jws-1", "jws-1", "jws-1"])
        #expect(failed.reportResults[1] == .transientFailure)

        verify.answers["jws-1"] = .status(SdkPurchaseReportStatusPending)
        let pending = await reporter.reportEntitlements([proof(1, networkId)], networkId: networkId, force: false)
        #expect(verify.calls.count == 6)
        #expect(pending.reportResults[1] == .transientFailure)

        verify.answers["jws-1"] = nil
        let credited = await reporter.reportEntitlements([proof(1, networkId)], networkId: networkId, force: false)
        #expect(verify.calls.count == 7)
        #expect(credited.reportResults[1] == .credited)
    }

    @Test func withoutASessionNothingIsReportedButTheScanStillClassifies() async {
        let verify = FakeVerify()
        verify.hasSession = false
        let reporter = makeReporter(defaults: makeDefaults(), verify: verify)

        let scan = await reporter.reportEntitlements(
            [proof(1, networkId), proof(2, networkId), proof(3, otherNetworkId)],
            networkId: networkId,
            force: false
        )
        #expect(verify.calls.isEmpty)
        #expect(scan.foundCurrent)
        #expect(scan.foundOther)
        #expect(scan.reportResults[1] == .deferredNoSession)
        #expect(scan.reportResults[2] == nil)

        verify.hasSession = true
        _ = await reporter.reportEntitlements([proof(1, networkId), proof(2, networkId)], networkId: networkId, force: false)
        #expect(verify.calls == ["jws-1", "jws-2"])
    }

    @Test func terminalAnswersOtherThanCreditAreNotRetried() async {
        let verify = FakeVerify()
        verify.answers["jws-1"] = .status(SdkPurchaseReportStatusInvalid)
        verify.answers["jws-2"] = .status(SdkPurchaseReportStatusWrongNetwork)
        let reporter = makeReporter(defaults: makeDefaults(), verify: verify)

        let scan = await reporter.reportEntitlements([proof(1, networkId), proof(2, networkId)], networkId: networkId, force: false)
        #expect(scan.reportResults[1] == .invalid)
        #expect(scan.reportResults[2] == .wrongNetwork)
        #expect(!scan.newlyCredited)

        _ = await reporter.reportEntitlements([proof(1, networkId), proof(2, networkId)], networkId: networkId, force: false)
        #expect(verify.calls == ["jws-1", "jws-2"])
    }

    @Test func withoutANetworkEveryEntitlementIsAnotherNetworks() async {
        let verify = FakeVerify()
        let reporter = makeReporter(defaults: makeDefaults(), verify: verify)

        let scan = await reporter.reportEntitlements([proof(1, networkId)], networkId: nil, force: true)
        #expect(verify.calls.isEmpty)
        #expect(!scan.foundCurrent)
        #expect(scan.foundOther)
    }

    // MARK: persisted proofs (report-then-finish crash recovery)

    private func seedPending(_ defaults: UserDefaults, _ transactionIds: [UInt64]) {
        let records = transactionIds.map { transactionId in
            ["transactionId": transactionId, "jws": "jws-\(transactionId)", "attemptCount": 0, "firstSeen": 0] as [String: Any]
        }
        defaults.set(try! JSONSerialization.data(withJSONObject: records), forKey: "ur.pendingPurchaseReports")
    }

    private func pendingTransactionIds(_ defaults: UserDefaults) -> [UInt64] {
        guard let data = defaults.data(forKey: "ur.pendingPurchaseReports"),
              let records = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return records.compactMap { ($0["transactionId"] as? NSNumber)?.uint64Value }.sorted()
    }

    @Test func persistedProofsAreReportedAndClearedOnATerminalAnswer() async {
        let defaults = makeDefaults()
        seedPending(defaults, [5, 6])
        let verify = FakeVerify()
        verify.answers["jws-6"] = .transportFailure
        let reporter = makeReporter(defaults: defaults, verify: verify)

        await reporter.retryPersistedReports()

        #expect(verify.calls.filter { $0 == "jws-5" }.count == 1)
        #expect(verify.calls.filter { $0 == "jws-6" }.count == 3)
        // the terminal one is dropped, the failed one kept for the next pass
        #expect(pendingTransactionIds(defaults) == [6])
    }

    @Test func persistedProofsWaitForASession() async {
        let defaults = makeDefaults()
        seedPending(defaults, [5])
        let verify = FakeVerify()
        verify.hasSession = false
        let reporter = makeReporter(defaults: defaults, verify: verify)

        await reporter.retryPersistedReports()
        #expect(verify.calls.isEmpty)
        #expect(pendingTransactionIds(defaults) == [5])

        verify.hasSession = true
        await reporter.retryPersistedReports()
        #expect(verify.calls == ["jws-5"])
        #expect(pendingTransactionIds(defaults).isEmpty)
    }
}

#endif
