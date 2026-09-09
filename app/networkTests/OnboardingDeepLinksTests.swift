import Foundation
import Testing
@testable import URnetwork

struct OnboardingDeepLinksTests {

    @Test func theFourStepsRouteAndOthersDoNot() {
        #expect(OnboardingDestination(url: URL(string: "urnetwork://onboarding/connect")!) == .connect)
        #expect(OnboardingDestination(url: URL(string: "urnetwork://onboarding/widgets?t=abc")!) == .widgets)
        #expect(OnboardingDestination(url: URL(string: "urnetwork://onboarding/offer")!) == .offer)
        #expect(OnboardingDestination(url: URL(string: "urnetwork://onboarding/elsewhere")!) == nil)
        #expect(OnboardingDestination(url: URL(string: "urnetwork://widgets/connect")!) == nil)
        #expect(OnboardingDestination(url: URL(string: "https://ur.io/c")!) == nil)
    }

    @Test func theFeedbackLinkCarriesTheOneTapAnswer() {
        #expect(OnboardingDestination(url: URL(string: "urnetwork://onboarding/feedback?r=4&t=tok")!)
            == .feedback(rating: 4, reason: nil, token: "tok"))
        #expect(OnboardingDestination(url: URL(string: "urnetwork://onboarding/feedback?why=not_working")!)
            == .feedback(rating: nil, reason: "not_working", token: nil))
        // a rating outside 1–5 is dropped, not routed
        #expect(OnboardingDestination(url: URL(string: "urnetwork://onboarding/feedback?r=9")!)
            == .feedback(rating: nil, reason: nil, token: nil))
    }

    @Test func aReasonBecomesTheFeedbackText() {
        #expect(FeedbackPrefill(rating: nil, reason: "trust", token: nil).reasonText == "I'm not sure I trust a VPN")
        #expect(FeedbackPrefill(rating: nil, reason: "unknown", token: nil).reasonText == nil)
    }
}
