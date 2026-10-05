//
//  GuestPurchaseRefusalTests.swift
//  networkTests
//
//  The server refuses a Stripe payment sheet or checkout session for a legacy
//  guest network with error.code guest_sign_in_required (server
//  refuseGuestPurchase). That refusal opens the add-sign-in sheet
//  (GuestPurchaseGate) instead of an error: a refreshed guest reads as an
//  account until the balance reports it, so the app could get this far.
//

import Foundation
import Testing
import URnetworkSdk
@testable import URnetwork

@MainActor
struct GuestPurchaseRefusalTests {

    private static let message = "Add a sign-in to your account before buying a plan."

    @Test func theGuestCodeIsTheSignInRefusal() {
        #expect(SdkPurchaseErrorCodeGuestSignInRequired == "guest_sign_in_required")
        #expect(StripeBillingError.refused(code: "guest_sign_in_required", message: Self.message) == .guestSignInRequired)
    }

    @Test func otherRefusalsKeepTheServersMessage() {
        // an older server sends no code; other refusals have none
        #expect(StripeBillingError.refused(code: "", message: "Unknown plan.") == .server("Unknown plan."))
        #expect(StripeBillingError.refused(code: "GUEST_SIGN_IN_REQUIRED", message: Self.message) == .server(Self.message))
        #expect(StripeBillingError.refused(code: "verify_rate_limited", message: "Too many.") == .server("Too many."))
    }

    @MainActor
    private final class IdleConfirmation: PurchaseConfirming {
        var onStateChanged: ((String) -> Void)?
        func start() {}
        func stop() {}
        func setForeground(_ foreground: Bool) {}
        func startPurchaseConfirmation() {}
    }

    @Test func theRefusalMarksTheNetworkAGuest() {
        // isPro keeps the 30 s background poll (a real timer) out of the test
        let viewModel = SubscriptionBalanceViewModel(
            urApiService: MockUrApiService(),
            isPro: true,
            refreshJwt: {},
            purchaseConfirmation: IdleConfirmation()
        )
        // a refreshed guest: no claim, and the balance has not said so yet
        #expect(GuestAccount.purchaseEntry(isGuest: GuestAccount.isGuest(guestModeClaim: false, serverGuest: viewModel.isGuest)) == .checkout)

        viewModel.serverRefusedGuestPurchase()

        #expect(viewModel.isGuest)
        #expect(GuestAccount.purchaseEntry(isGuest: GuestAccount.isGuest(guestModeClaim: false, serverGuest: viewModel.isGuest)) == .addSignInMethod)
    }

    // …/apple/app/networkTests/GuestPurchaseRefusalTests.swift -> …/apple/app
    private static let appRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static func source(_ path: String) throws -> String {
        try String(contentsOf: appRoot.appendingPathComponent(path), encoding: .utf8)
    }

    /// The refusal reaches the gates: MainView marks the network a guest (the
    /// upgrade sheet and the offer sheet are behind GuestPurchaseGate), and the
    /// intro, which sells a plan without a gate, opens the upgrade sheet.
    @Test func theRefusalReachesTheGates() throws {
        let client = try Self.source("network/Shared/Billing/StripeBillingClient.swift")
        #expect(client.components(separatedBy: "throw StripeBillingError.refused(code: error.code, message: error.message)").count - 1 == 2)

        let main = try Self.source("network/Main/MainView.swift")
        let mainChange = try #require(main.range(of: ".onChange(of: stripeSubscriptionStore.guestSignInRequiredSequence)"))
        #expect(main.range(of: "subscriptionBalanceViewModel.serverRefusedGuestPurchase()", range: mainChange.upperBound..<main.endIndex) != nil)

        let intro = try Self.source("network/Shared/Views/Introduction/IntroductionView.swift")
        let introChange = try #require(intro.range(of: ".onChange(of: stripeSubscriptionStore.guestSignInRequiredSequence)"))
        #expect(intro.range(of: "openGuestConversion()", range: introChange.upperBound..<intro.endIndex) != nil)
    }
}
