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
}
