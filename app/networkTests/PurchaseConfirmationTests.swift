import Foundation
import Testing
import URnetworkSdk
@testable import URnetwork

/**
 * The post-purchase confirmation (finding A2 in server/UPGRADE.md §3) runs on
 * the SDK SubscriptionBalanceViewController: the view model starts it, forwards
 * the app's active state (which pauses the controller's polling budget) and
 * gives up only when the controller says so. The controller is a fake that
 * records calls and emits states on demand, so nothing here polls, waits or
 * reads a clock.
 */
@MainActor
struct PurchaseConfirmationTests {

    @MainActor
    private final class FakePurchaseConfirmation: PurchaseConfirming {
        enum Call: Equatable {
            case start
            case stop
            case setForeground(Bool)
            case startPurchaseConfirmation
        }

        var onStateChanged: ((String) -> Void)?
        var calls: [Call] = []

        func start() { calls.append(.start) }
        func stop() { calls.append(.stop) }
        func setForeground(_ foreground: Bool) { calls.append(.setForeground(foreground)) }
        func startPurchaseConfirmation() { calls.append(.startPurchaseConfirmation) }

        func emit(_ state: String) {
            onStateChanged?(state)
        }
    }

    private func makeViewModel(
        _ confirmation: FakePurchaseConfirmation,
        isPro: Bool = true
    ) -> SubscriptionBalanceViewModel {
        // isPro keeps the 30 s background poll (a real timer) out of these tests
        SubscriptionBalanceViewModel(
            urApiService: MockUrApiService(),
            isPro: isPro,
            refreshJwt: {},
            purchaseConfirmation: confirmation
        )
    }

    @Test func aPurchaseStartsTheSdkConfirmation() {
        let confirmation = FakePurchaseConfirmation()
        let viewModel = makeViewModel(confirmation)
        viewModel.setActive(true)
        confirmation.calls.removeAll()

        viewModel.startPolling()

        // confirmation before start: the budget is armed when the controller
        // starts, with no baseline snapshot (confirm on pro with a balance)
        #expect(confirmation.calls == [.startPurchaseConfirmation, .start])
        #expect(viewModel.isPolling)
        #expect(!viewModel.purchaseConfirmationTimedOut)

        // a second purchase hand-back while confirming does not restart it
        viewModel.startPolling()
        #expect(confirmation.calls == [.startPurchaseConfirmation, .start])
    }

    @Test func timeInactiveDoesNotRunOutTheConfirmation() {
        let confirmation = FakePurchaseConfirmation()
        let viewModel = makeViewModel(confirmation)
        viewModel.setActive(true)
        viewModel.startPolling()
        confirmation.calls.removeAll()

        // the buyer leaves the app (an SCA step, the App Store's sheets) and
        // comes back: the controller's budget is paused and resumed with it
        viewModel.setActive(false)
        viewModel.setActive(true)

        #expect(confirmation.calls == [.setForeground(false), .setForeground(true)])
        // the view model has no deadline of its own: still waiting
        #expect(viewModel.isPolling)
        #expect(!viewModel.purchaseConfirmationTimedOut)
    }

    @Test func theControllerGivingUpIsSurfaced() {
        let confirmation = FakePurchaseConfirmation()
        let viewModel = makeViewModel(confirmation)
        viewModel.setActive(true)
        viewModel.startPolling()
        confirmation.calls.removeAll()

        confirmation.emit(SdkPurchaseConfirmationStateWaitingForConfirmation)
        #expect(!viewModel.purchaseConfirmationTimedOut)

        confirmation.emit(SdkPurchaseConfirmationStateConfirmationGaveUp)
        #expect(viewModel.purchaseConfirmationTimedOut)
        #expect(!viewModel.isPolling)
        #expect(confirmation.calls == [.stop])

        // the idle that follows the stop changes nothing
        confirmation.emit(SdkPurchaseConfirmationStateIdle)
        #expect(viewModel.purchaseConfirmationTimedOut)

        // a new attempt starts clean
        viewModel.startPolling()
        #expect(!viewModel.purchaseConfirmationTimedOut)
        #expect(viewModel.isPolling)
        #expect(confirmation.calls == [.stop, .startPurchaseConfirmation, .start])
    }

    @Test func aConfirmedPurchaseEndsTheConfirmation() {
        let confirmation = FakePurchaseConfirmation()
        let viewModel = makeViewModel(confirmation)
        viewModel.setActive(true)
        viewModel.startPolling()
        confirmation.calls.removeAll()

        confirmation.emit(SdkPurchaseConfirmationStateConfirmed)

        #expect(!viewModel.isPolling)
        #expect(!viewModel.purchaseConfirmationTimedOut)
        #expect(confirmation.calls == [.stop])
    }

    @Test func aStateWithNoConfirmationRunningIsIgnored() {
        let confirmation = FakePurchaseConfirmation()
        let viewModel = makeViewModel(confirmation)
        viewModel.setActive(true)

        confirmation.emit(SdkPurchaseConfirmationStateConfirmationGaveUp)

        #expect(!viewModel.purchaseConfirmationTimedOut)
        #expect(!confirmation.calls.contains(.stop))
    }

    @Test func stoppingThePollStopsTheController() {
        let confirmation = FakePurchaseConfirmation()
        let viewModel = makeViewModel(confirmation, isPro: false)
        viewModel.startPolling()
        confirmation.calls.removeAll()

        // the jwt turned pro (the purchase landed) while confirming
        viewModel.updateIsPro(true)

        #expect(!viewModel.isPolling)
        #expect(confirmation.calls == [.stop])
    }
}
