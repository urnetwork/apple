import Foundation
import Testing
@testable import URnetwork

/**
 * A legacy guest's "Create an account" (finding A4 in server/UPGRADE.md §3)
 * converts the guest network in place: a sign-in method is added to it and the
 * jwt is re-signed. It must never leave the network, which is where a guest's
 * paid plan and balance live.
 */
@MainActor
struct GuestAccountConversionTests {

    @MainActor
    private final class FakeSession: GuestAccountSession {
        enum Call: Equatable {
            case refreshJwt
            case logout
        }

        var calls: [Call] = []

        func refreshJwt() { calls.append(.refreshJwt) }
        func logout() { calls.append(.logout) }
    }

    @Test func addingASignInMethodKeepsTheGuestNetwork() {
        let session = FakeSession()

        GuestAccountConversion(session: session).signInMethodAdded()

        // re-signed for the same network; never logged out to another one
        #expect(session.calls == [.refreshJwt])
    }

    @Test func aGuestIsOnlyAJwtThatSaysSo() {
        #expect(GuestAccount.isGuest(guestModeClaim: true))
        #expect(!GuestAccount.isGuest(guestModeClaim: false))
        // no jwt (yet) is not a guest
        #expect(!GuestAccount.isGuest(guestModeClaim: nil))
    }
}
