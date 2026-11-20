//
//  AccountSignInNotice.swift
//  URnetwork
//
//  What the main screens tell the user when the account's sign-in needs
//  signing in again while this device stays signed in (server
//  session/REVOKE-FINAL.md R9, REVOKE-UI-FINAL.md §5). The account's
//  credential was rejected while this device's client credential belongs to
//  another session, so the SDK cleared only the account credential, kept the
//  device, and reported its api's AccountSignInRequired rather than a logout.
//  Nothing is signed out or disconnected for it: the notice says that the
//  account needs a sign-in (Account > Sessions shows its own sign-in state),
//  and that another device signed the session out only when the SDK gives
//  that trusted cause (Api.GetAccountSignInRequiredCause). DeviceManager
//  keeps it until the user dismisses it, or until the next sign-in or
//  sign-out.
//

import Foundation
import URnetworkSdk

enum AccountSignInNotice: Equatable {
    /// the account's sign-in was rejected for a reason the server did not
    /// confirm as a revocation
    case signInRequired
    /// the server confirmed that another device signed the account's
    /// sign-in out
    case signedOutRemotely

    /// The notice for the cause the SDK gave with AccountSignInRequired: its
    /// trusted session-revoked cause, or any other, empty included.
    init(accountSignInRequiredCause: String) {
        self = accountSignInRequiredCause == SdkAuthLogoutCauseSessionRevoked ? .signedOutRemotely : .signInRequired
    }

    var message: String {
        let signInAgain = String(localized: "Sign in again to manage sessions.")
        switch self {
        case .signInRequired:
            return signInAgain
        case .signedOutRemotely:
            return String(localized: "This session was signed out from another device.") + " " + signInAgain
        }
    }
}
