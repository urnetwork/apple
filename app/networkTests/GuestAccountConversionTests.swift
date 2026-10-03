import Foundation
import Testing
@testable import URnetwork

/**
 * A legacy guest's "Create an account" (findings A4 and D8 in
 * server/UPGRADE.md §3) converts the guest network in place: a sign-in method
 * is added to it, the jwt is re-signed and the balance refetched. It must
 * never leave the network, which is where a guest's paid plan and balance live.
 */
@MainActor
struct GuestAccountConversionTests {

    @MainActor
    private final class FakeSession: GuestAccountSession {
        enum Call: Equatable {
            case refreshJwt
            case refreshBalance
            case logout
        }

        var calls: [Call] = []

        func refreshJwt() { calls.append(.refreshJwt) }
        func refreshBalance() { calls.append(.refreshBalance) }
        func logout() { calls.append(.logout) }
    }

    @Test func addingASignInMethodKeepsTheGuestNetwork() {
        let session = FakeSession()

        GuestAccountConversion(session: session).signInMethodAdded()

        // re-signed for the same network and the guest flag refetched; never
        // logged out to another one
        #expect(session.calls == [.refreshJwt, .refreshBalance])
    }

    @Test func aGuestIsTheClaimOrTheServer() {
        #expect(GuestAccount.isGuest(guestModeClaim: true, serverGuest: false))
        #expect(!GuestAccount.isGuest(guestModeClaim: false, serverGuest: false))
        // no jwt (yet) is not a guest
        #expect(!GuestAccount.isGuest(guestModeClaim: nil, serverGuest: false))
    }
}
