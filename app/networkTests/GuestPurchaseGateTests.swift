import Foundation
import Testing
@testable import URnetwork

/**
 * Every token refresh signs the jwt without `guest_mode`, so after one refresh
 * a legacy guest network (no login method) no longer carries the claim. The
 * server reports it on the subscription balance (`guest`). A refreshed guest
 * must still be a guest, and must reach the in-place conversion, not the
 * checkout: a plan bought on a guest network is stranded there.
 */
struct GuestPurchaseGateTests {

    @Test func aRefreshedLegacyGuestIsAGuest() {
        #expect(GuestAccount.isGuest(guestModeClaim: false, serverGuest: true))
        #expect(GuestAccount.isGuest(guestModeClaim: nil, serverGuest: true))
    }

    @Test func aRefreshedLegacyGuestDoesNotReachCheckout() {
        let isGuest = GuestAccount.isGuest(guestModeClaim: false, serverGuest: true)
        #expect(GuestAccount.purchaseEntry(isGuest: isGuest) == .addSignInMethod)
    }

    @Test func anAccountReachesCheckout() {
        let isGuest = GuestAccount.isGuest(guestModeClaim: false, serverGuest: false)
        #expect(GuestAccount.purchaseEntry(isGuest: isGuest) == .checkout)
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
        #expect(GuestAccount.purchaseEntry(isGuest: isGuest, signInMethodAdded: true) == .checkout)
        #expect(GuestAccount.conversionClosed(signInMethodAdded: true) == .continueToCheckout)
    }

    /// A cancelled conversion is not a way into the checkout.
    @Test func aCancelledConversionClosesThePurchase() {
        let isGuest = GuestAccount.isGuest(guestModeClaim: false, serverGuest: true)
        #expect(GuestAccount.purchaseEntry(isGuest: isGuest, signInMethodAdded: false) == .addSignInMethod)
        #expect(GuestAccount.conversionClosed(signInMethodAdded: false) == .closePurchase)
    }
}
