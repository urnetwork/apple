import Foundation
import Testing
@testable import URnetwork

struct IntroductionRouteStateTests {

    @Test func communitySelectionAdvancesThroughEveryIntroductionStage() {
        var state = IntroductionRouteState()

        state.advance(to: .usage)
        #expect(state.path == [.usage])

        state.advance(to: .participate)
        #expect(state.path == [.usage, .participate])

        state.advance(to: .refer)
        #expect(state.path == [.usage, .participate, .refer])
    }

    @Test func staleOrDuplicateIntroductionActionsCannotResetTheRoute() {
        var state = IntroductionRouteState()
        state.advance(to: .usage)

        state.advance(to: .usage)
        state.advance(to: .refer)

        #expect(state.path == [.usage])
        state.advance(to: .participate)
        #expect(state.path == [.usage, .participate])
    }

    @Test func theOfferPageIsTheLastStopAndSkipLandsThereOnce() {
        var state = IntroductionRouteState()
        state.advance(to: .usage)
        state.advance(to: .participate)
        state.advance(to: .refer)
        state.advance(to: .quickConnect)
        state.advance(to: .offer)
        #expect(state.path.last == .offer)
        #expect(state.isOnOffer)
        // nothing comes after the offer
        state.advance(to: .usage)
        #expect(state.path.last == .offer)

        // Skip from page 2 lands on the offer page, and a second skip changes nothing
        var skipped = IntroductionRouteState()
        skipped.advance(to: .usage)
        skipped.skipToOffer()
        #expect(skipped.path == [.usage, .offer])
        skipped.skipToOffer()
        #expect(skipped.path == [.usage, .offer])

        // Skip from page 1 too
        var fromWelcome = IntroductionRouteState()
        fromWelcome.skipToOffer()
        #expect(fromWelcome.path == [.offer])
    }

    @Test func theStepsAreNamedForTheEvents() {
        #expect(IntroStep(route: .offer) == .offer)
        #expect(IntroStep.offer.name == "offer")
        #expect(IntroStep.offer.rawValue == 5)
        #expect(IntroStep.allCases.map(\.name) == ["welcome", "usage", "participate", "refer", "quickConnect", "offer"])
        var timing = IntroStepTiming()
        let start = Date()
        timing.shown(.usage, at: start)
        #expect(timing.elapsedMillis(.usage, at: start.addingTimeInterval(1.5)) == 1500)
        // a step never shown has no elapsed time
        #expect(timing.elapsedMillis(.refer) == 0)
    }
}
