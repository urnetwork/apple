//
//  SignedOutNotice.swift
//  URnetwork
//
//  What the sign-in screen tells the user, once, about the sign-out that
//  brought them there (server/session/REVOKE-UI-FINAL.md §5). With a device's
//  AuthLogout the SDK gives a cause (Device.GetAuthLogoutCause): its trusted
//  session-revoked cause when the server confirmed that another device signed
//  this session out, else "". Only that cause has a notice. This app's own
//  sign-out, this session signed out from Account > Sessions (the SDK gives
//  "" for both) and every other rejection keep the generic sign-out, with
//  nothing new to say.
//

import Foundation
import URnetworkSdk

enum SignedOutNotice: Equatable {
    /// the server confirmed that another device signed this session out
    case signedOutRemotely

    /// The notice for a device's logout cause: nil for every cause but the
    /// trusted session-revoked one, empty included.
    init?(authLogoutCause: String) {
        guard authLogoutCause == SdkAuthLogoutCauseSessionRevoked else {
            return nil
        }
        self = .signedOutRemotely
    }

    var message: String {
        switch self {
        case .signedOutRemotely:
            return String(localized: "This session was signed out from another device.")
        }
    }
}
