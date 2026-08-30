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
}
