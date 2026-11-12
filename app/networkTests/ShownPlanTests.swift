//
//  ShownPlanTests.swift
//  networkTests
//
//  The plan the plan cards show (support inbox 4074). In December 2025 the
//  balance read failed under database load and the app showed the failed read
//  as Free, with Get Pro, to networks whose paid plans were running. The sdk
//  decides the plan now (SubscriptionProTracker.GetShownPlan): only the server
//  says Free, and a read that is on its way or failed is not known. These run
//  the mapping, what the cards decide from it, and the sdk's tracker itself.
//  No network: the gomobile tracker and pure helpers only.
//

import Foundation
import Testing
import URnetworkSdk
@testable import URnetwork

struct ShownPlanTests {

    // MARK: the sdk's plan

    @Test func theSdksPlanMapsToWhatTheCardsShow() {
        #expect(ShownPlan.of(sdkPlan: "pro", lastReadFailed: false) == .pro)
        #expect(ShownPlan.of(sdkPlan: "pro", lastReadFailed: true) == .pro)
        #expect(ShownPlan.of(sdkPlan: "free", lastReadFailed: false) == .free)
        #expect(ShownPlan.of(sdkPlan: "free", lastReadFailed: true) == .free)
        #expect(ShownPlan.of(sdkPlan: "unknown", lastReadFailed: false) == .loading)
        #expect(ShownPlan.of(sdkPlan: "unknown", lastReadFailed: true) == .unreachable)
        // an answer this build does not know is not Free either
        #expect(ShownPlan.of(sdkPlan: "", lastReadFailed: false) == .loading)
        #expect(ShownPlan.of(sdkPlan: "supporter", lastReadFailed: true) == .unreachable)
    }

    @Test func theMappedStringsAreTheSdks() {
        #expect(SdkShownPlanPro == "pro")
        #expect(SdkShownPlanFree == "free")
        #expect(SdkShownPlanUnknown == "unknown")
    }

    // MARK: the plan cards

    @Test func aPlanNotKnownIsNeverFreeAndOffersNoUpgrade() {
        #expect(ShownPlan.loading.load == .loading)
        #expect(ShownPlan.unreachable.load == .failed)
        #expect(!ShownPlan.loading.offersUpgrade)
        #expect(!ShownPlan.unreachable.offersUpgrade)
    }

    @Test func aKnownPlanShowsItsLabelAndOnlyFreeOffersGetPro() {
        #expect(ShownPlan.pro.load == .loaded)
        #expect(ShownPlan.free.load == .loaded)
        #expect(ShownPlan.free.offersUpgrade)
        #expect(!ShownPlan.pro.offersUpgrade)
    }

    // MARK: the sdk's tracker

    /// An unsigned network jwt with a `pro` claim; the issue time makes a
    /// renewal of the same claims another jwt.
    private static func networkJwt(pro: Bool, issuedAt: Int) -> String {
        func base64url(_ text: String) -> String {
            Data(text.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let header = base64url(#"{"alg":"none"}"#)
        let payload = base64url(#"{"network_id":"00000000-0000-0000-0000-000000000011","pro":\#(pro),"iat":\#(issuedAt)}"#)
        return "\(header).\(payload)."
    }

    private static func shown(_ tracker: SdkSubscriptionProTracker) -> ShownPlan {
        ShownPlan.of(sdkPlan: tracker.getShownPlan(), lastReadFailed: tracker.getLastReadFailed())
    }

    @Test func aPayingNetworkWhoseReadFailsIsNotShownFree() throws {
        let tracker = try #require(SdkNewSubscriptionProTracker())
        // the stored jwt was minted before the purchase: its claim says Free
        _ = tracker.setJwt(Self.networkJwt(pro: false, issuedAt: 1))
        #expect(Self.shown(tracker) == .loading)

        // the balance read fails, as on 2025-12-04
        _ = tracker.balanceFailed()
        #expect(Self.shown(tracker) == .unreachable)
        #expect(!tracker.getIsPro())

        // the read comes back: the server's answer, and the jwt refresh the
        // failure did not use up
        #expect(tracker.balanceLoaded(true))
        #expect(Self.shown(tracker) == .pro)

        // a read that fails after the server answered keeps the answer
        _ = tracker.balanceFailed()
        #expect(Self.shown(tracker) == .pro)
    }

    @Test func onlyTheServerSaysFree() throws {
        let tracker = try #require(SdkNewSubscriptionProTracker())
        _ = tracker.setJwt(Self.networkJwt(pro: false, issuedAt: 1))
        _ = tracker.balanceLoaded(false)
        #expect(Self.shown(tracker) == .free)

        // a Pro claim is Pro until the server answers, failed read or not
        tracker.reset()
        _ = tracker.setJwt(Self.networkJwt(pro: true, issuedAt: 2))
        #expect(Self.shown(tracker) == .pro)
        _ = tracker.balanceFailed()
        #expect(Self.shown(tracker) == .pro)

        // a sign out: not known
        tracker.reset()
        #expect(Self.shown(tracker) == .loading)
    }
}
