import Foundation
import Testing
@testable import URnetwork

/**
 * An instant account is the server's seedphrase path: terms and no login
 * method. The app also sent guest_mode = true, which the server no longer
 * reads (NetworkCreateArgs has no guest_mode since the seedphrase path) and
 * which describes a network kind the server does not create any more.
 */
struct InstantAccountArgsTests {

    @Test func anInstantAccountIsNotAskedForAsAGuest() {
        let args = UrApiService.instantAccountArgs(referralCode: nil, productUpdatesOptOut: false)
        #expect(!args.guestMode)
    }

    @Test func anInstantAccountHasTermsAndNoLoginMethod() {
        let args = UrApiService.instantAccountArgs(referralCode: "ABC123", productUpdatesOptOut: true)
        #expect(args.terms)
        #expect(args.userAuth.isEmpty)
        #expect(args.password.isEmpty)
        #expect(args.authJwt.isEmpty)
        #expect(args.walletAuth == nil)
        #expect(args.referralCode == "ABC123")
        #expect(args.productUpdatesOptOut)
        #expect(!args.networkName.isEmpty)
    }
}
