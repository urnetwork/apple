//
//  AuthMethods.swift
//  URnetwork
//

import URnetworkSdk

// Shared by SettingsForm-iOS.swift and SettingsForm-macOS.swift so both
// platforms read auth-method state identically.

func authTypesContains(_ authTypes: SdkStringList?, _ method: String) -> Bool {
    guard let authTypes else { return false }
    for i in 0..<authTypes.len() {
        if authTypes.get(i) == method {
            return true
        }
    }
    return false
}

func parseAuthMethods(_ networkUser: SdkNetworkUser) -> [String] {
    var methods: [String] = []

    // Read from the new auth_types array returned by GET /network/user
    if let authTypes = networkUser.authTypes, authTypes.len() > 0 {
        for i in 0..<authTypes.len() {
            let method = authTypes.get(i)
            if !method.isEmpty {
                methods.append(method)
            }
        }
    } else {
        // Fallback for old server: read single authType + userAuth
        let authType = networkUser.authType
        if !authType.isEmpty { methods.append(authType) }
        let userAuth = networkUser.userAuth
        if !userAuth.isEmpty {
            let methodLabel = userAuth.contains("@") ? "email" : userAuth
            if !methods.contains(methodLabel) {
                methods.append(methodLabel)
            }
        }
    }

    return methods
}

/// The address Change password mails a reset link to, or nil when the account
/// has no password sign-in. The server's reset only rewrites an email or phone
/// password sign-in, while `userAuth` is the identity the account was created
/// with: a Google or Apple account has one but no password (the reset
/// "succeeded" and changed nothing), and an account that added an email and
/// password later has none.
func passwordResetUserAuth(userAuth: String?, authType: String, authTypes: [String]) -> String? {
    guard let userAuth, !userAuth.isEmpty else { return nil }
    let listed = authTypes.filter { !$0.isEmpty }
    // an old server sends no list, only the single auth type
    let hasPasswordSignIn = listed.isEmpty
        ? authType == "password"
        : listed.contains("email") || listed.contains("phone")
    return hasPasswordSignIn ? userAuth : nil
}

func passwordResetUserAuth(_ networkUser: SdkNetworkUser) -> String? {
    var authTypes: [String] = []
    if let list = networkUser.authTypes {
        for i in 0..<list.len() {
            authTypes.append(list.get(i))
        }
    }
    return passwordResetUserAuth(
        userAuth: networkUser.userAuth,
        authType: networkUser.authType,
        authTypes: authTypes
    )
}

func methodDisplayName(_ method: String) -> String {
    switch method {
    case "email": return "Email"
    case "google": return "Google"
    case "apple": return "Apple"
    case "solana": return "Solana Wallet"
    case "seedphrase": return "Seedphrase"
    default: return method.capitalized
    }
}
