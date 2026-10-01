//
//  Config.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2024/12/06.
//

import Foundation

struct Config {
    /// GIDClientID from Info.plist (UR_GOOGLE_CLIENT_ID per target), or ""
    /// when this build has no Google OAuth client -- the direct-download
    /// build until DIRECT_GOOGLE_CLIENT_ID is set. See
    /// GoogleSignInConfiguration.
    static var googleClientID: String {
        Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String ?? ""
    }

    /// Whether the Google sign-in buttons should be offered at all.
    static var isGoogleSignInConfigured: Bool {
        GoogleSignInConfiguration.isConfigured(clientId: googleClientID)
    }

    /// Whether the native Sign in with Apple button should be offered at
    /// all: false in the direct-download build, whose Developer ID profile
    /// lacks the applesignin entitlement. See AppleSignInConfiguration.
    static var isAppleSignInConfigured: Bool {
        AppleSignInConfiguration.isConfigured
    }
}
