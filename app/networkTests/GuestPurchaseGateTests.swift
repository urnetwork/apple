import Foundation
import Testing
@testable import URnetwork

/**
 * Every token refresh signs the jwt without `guest_mode`, so after one refresh
 * a legacy guest network (no login method) no longer carries the claim. The
 * server reports it on the subscription balance (`guest`). A refreshed guest
 * must still be a guest, and must reach the in-place conversion, not the
 * checkout: a plan bought on a guest network is stranded there.
 *
 * Until the balance answers, a refreshed guest reads as an account, so the
 * App Store checkout, which the server cannot refuse, waits for the answer
 * (support inbox 7334: an App Store year bought on the guest network the app
 * was in).
 */
struct GuestPurchaseGateTests {

    /// The App Store build's entry once the guest status is known.
    private static func appStoreEntry(isGuest: Bool, signInMethodAdded: Bool = false) -> GuestAccount.PurchaseEntry {
        GuestAccount.purchaseEntry(
            isGuest: isGuest,
            guestKnown: true,
            checkoutRefusesGuests: BillingDistribution.appStore.checkoutRefusesGuests,
            signInMethodAdded: signInMethodAdded
        )
    }

    @Test func aRefreshedLegacyGuestIsAGuest() {
        #expect(GuestAccount.isGuest(guestModeClaim: false, serverGuest: true))
        #expect(GuestAccount.isGuest(guestModeClaim: nil, serverGuest: true))
    }

    @Test func aRefreshedLegacyGuestDoesNotReachCheckout() {
        let isGuest = GuestAccount.isGuest(guestModeClaim: false, serverGuest: true)
        #expect(Self.appStoreEntry(isGuest: isGuest) == .addSignInMethod)
    }

    @Test func anAccountReachesCheckout() {
        let isGuest = GuestAccount.isGuest(guestModeClaim: false, serverGuest: false)
        #expect(Self.appStoreEntry(isGuest: isGuest) == .checkout)
    }

    /**
     * The conversion is opened from the purchase the guest was starting. Once
     * it added a sign-in method, closing it continues to that checkout at once
     * (the re-signed jwt and the refetched balance are still in flight, so the
     * guest signals still read true); it used to close the purchase with it,
     * and the user had to open the upgrade again.
     */
    @Test func aConvertedGuestContinuesToTheCheckout() {
        let isGuest = GuestAccount.isGuest(guestModeClaim: false, serverGuest: true)
        #expect(Self.appStoreEntry(isGuest: isGuest, signInMethodAdded: true) == .checkout)
        #expect(GuestAccount.conversionClosed(signInMethodAdded: true) == .continueToCheckout)
    }

    /// A cancelled conversion is not a way into the checkout.
    @Test func aCancelledConversionClosesThePurchase() {
        let isGuest = GuestAccount.isGuest(guestModeClaim: false, serverGuest: true)
        #expect(Self.appStoreEntry(isGuest: isGuest, signInMethodAdded: false) == .addSignInMethod)
        #expect(GuestAccount.conversionClosed(signInMethodAdded: false) == .closePurchase)
    }

    // MARK: an unknown guest status

    /// The status is known once the jwt claims a guest or the server answered
    /// the balance; a refreshed guest with no answer yet is unknown.
    @Test func theGuestStatusIsKnownFromTheClaimOrTheServer() {
        #expect(GuestAccount.isGuestKnown(guestModeClaim: true, serverAnswered: false))
        #expect(GuestAccount.isGuestKnown(guestModeClaim: false, serverAnswered: true))
        #expect(GuestAccount.isGuestKnown(guestModeClaim: nil, serverAnswered: true))
        #expect(!GuestAccount.isGuestKnown(guestModeClaim: false, serverAnswered: false))
        #expect(!GuestAccount.isGuestKnown(guestModeClaim: nil, serverAnswered: false))
    }

    /// A refreshed guest before the balance answers, or after the read
    /// failed, reads as an account. The App Store would charge it for a
    /// network nothing signs back in to, so its checkout waits.
    @Test func anUnknownGuestStatusDoesNotReachTheAppStoreCheckout() {
        let entry = GuestAccount.purchaseEntry(
            isGuest: GuestAccount.isGuest(guestModeClaim: false, serverGuest: false),
            guestKnown: GuestAccount.isGuestKnown(guestModeClaim: false, serverAnswered: false),
            checkoutRefusesGuests: BillingDistribution.appStore.checkoutRefusesGuests
        )
        #expect(entry == .checkingGuest)
    }

    /// The direct download's Stripe and crypto checkouts are refused by the
    /// server for a guest, and the refusal opens the conversion, so they do
    /// not wait.
    @Test func anUnknownGuestStatusReachesACheckoutTheServerGuards() {
        #expect(BillingDistribution.direct.checkoutRefusesGuests)
        #expect(!BillingDistribution.appStore.checkoutRefusesGuests)
        let entry = GuestAccount.purchaseEntry(
            isGuest: false,
            guestKnown: false,
            checkoutRefusesGuests: BillingDistribution.direct.checkoutRefusesGuests
        )
        #expect(entry == .checkout)
    }

    /// A guest goes to the conversion whether or not the server answered,
    /// and a sign-in method added from the entry continues to the checkout.
    @Test func aGuestOrAConvertedGuestDoesNotWait() {
        #expect(GuestAccount.purchaseEntry(isGuest: true, guestKnown: false, checkoutRefusesGuests: false) == .addSignInMethod)
        #expect(GuestAccount.purchaseEntry(isGuest: true, guestKnown: false, checkoutRefusesGuests: false, signInMethodAdded: true) == .checkout)
    }

    /// The view model's status is unknown until a balance read succeeds.
    @Test @MainActor func theStatusIsUnknownBeforeTheBalanceAnswers() {
        let viewModel = SubscriptionBalanceViewModel(
            urApiService: MockUrApiService(),
            // isPro keeps the 30 s background poll (a real timer) out of the test
            isPro: true,
            refreshJwt: {},
            purchaseConfirmation: IdleConfirmation()
        )
        #expect(!viewModel.isGuest)
        #expect(!viewModel.isGuestKnown)
    }

    @MainActor
    private final class IdleConfirmation: PurchaseConfirming {
        var onStateChanged: ((String) -> Void)?
        func start() {}
        func stop() {}
        func setForeground(_ foreground: Bool) {}
        func startPurchaseConfirmation() {}
    }

    // MARK: every upgrade sheet is gated

    // …/apple/app/networkTests/GuestPurchaseGateTests.swift -> …/apple/app
    private static let appRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static func source(_ path: String) throws -> String {
        try String(contentsOf: appRoot.appendingPathComponent(path), encoding: .utf8)
    }

    /// The Account screen's upgrade sheet had no gate: only its Get Pro
    /// button hid for a known guest, so a refreshed guest opened the App
    /// Store purchase there, and the direct download's crypto entries and a
    /// guest refusal reached the plans. Every sheet that sells Pro presents
    /// the upgrade inside GuestPurchaseGate.
    @Test func everyUpgradeSheetIsInsideTheGate() throws {
        let paths = [
            "network/Main/Account/AccountRootView.swift",
            "network/Main/Connect/ConnectView-iOS.swift",
            "network/Main/Connect/ConnectView-macOS.swift",
        ]
        for path in paths {
            let source = try Self.source(path)
            var searchStart = source.startIndex
            var sheets = 0
            while let upgrade = source.range(of: "UpgradeSubscriptionSheet(", range: searchStart..<source.endIndex) {
                let presented = try #require(
                    source.range(of: ".sheetOffTheFold(", options: .backwards, range: source.startIndex..<upgrade.lowerBound),
                    "\(path): an upgrade sheet outside a sheet"
                )
                #expect(
                    source[presented.upperBound..<upgrade.lowerBound].contains("GuestPurchaseGate("),
                    "\(path): an upgrade sheet outside the gate"
                )
                sheets += 1
                searchStart = upgrade.upperBound
            }
            #expect(0 < sheets, "\(path) presents no upgrade sheet")
        }
    }
}
