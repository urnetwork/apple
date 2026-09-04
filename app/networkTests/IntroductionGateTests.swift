import SwiftUI
import Testing
@testable import URnetwork

struct IntroductionGateTests {

    @Test func aNewNetworkSeesTheIntroductionUntilItIsComplete() {
        #expect(IntroductionGate.shouldDisplay(introductionComplete: false, isPro: false))
        #expect(!IntroductionGate.shouldDisplay(introductionComplete: true, isPro: false))
    }

    @Test func proNetworksAndAnUnknownBalanceNeverSeeIt() {
        #expect(!IntroductionGate.shouldDisplay(introductionComplete: false, isPro: true))
        #expect(!IntroductionGate.shouldDisplay(
            introductionComplete: false,
            isPro: false,
            balanceUnavailable: true
        ))
    }

    @Test func finishingPersistsAndKeepsTheIntroductionAwayOnRebuild() {
        var complete = false
        var persisted = 0
        let binding = Binding(get: { complete }, set: { complete = $0 })

        IntroductionGate.finish(introductionComplete: binding, persist: { persisted += 1 })

        #expect(complete)
        #expect(persisted == 1)
        // a rebuilt navigation root re-evaluates the gate from the same state
        #expect(!IntroductionGate.shouldDisplay(introductionComplete: complete, isPro: false))
    }

    @Test func finishingAgainStillPersistsWithoutReEmittingTheBinding() {
        var complete = true
        var writes = 0
        var persisted = 0
        let binding = Binding(get: { complete }, set: { complete = $0; writes += 1 })

        IntroductionGate.finish(introductionComplete: binding, persist: { persisted += 1 })

        #expect(complete)
        #expect(writes == 0)
        #expect(persisted == 1)
    }
}
