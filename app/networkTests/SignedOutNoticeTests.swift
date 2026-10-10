//
//  SignedOutNoticeTests.swift
//  networkTests
//

import Foundation
import Testing
import URnetworkSdk
@testable import URnetwork

/**
 * The logout cause's notice (REVOKE-UI-FINAL.md §5): only the SDK's trusted
 * session-revoked cause says the session was signed out from another device.
 * "" (this app's own sign-out, this session signed out from Account >
 * Sessions, a generic rejection) and every other cause say nothing new.
 */
struct SignedOutNoticeTests {

    @Test func theSdkCauseIsTheSessionRevokedCode() {
        #expect(SdkAuthLogoutCauseSessionRevoked == "session_revoked")
    }

    @Test func onlyTheSessionRevokedCauseHasANotice() {
        #expect(SignedOutNotice(authLogoutCause: SdkAuthLogoutCauseSessionRevoked) == .signedOutRemotely)
        for cause in ["", "SESSION_REVOKED", " session_revoked", "session_revoked ", "client_removed", "signed_out"] {
            #expect(SignedOutNotice(authLogoutCause: cause) == nil, "cause \(cause)")
        }
    }

    @Test func theNoticeSaysAnotherDeviceSignedThisSessionOut() {
        #expect(SignedOutNotice.signedOutRemotely.message == "This session was signed out from another device.")
    }
}
