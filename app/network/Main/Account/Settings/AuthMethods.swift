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

/// An email or phone password sign-in of the account (the server's
/// `user_auths`), kept free of the sdk so the choice below is tested without it.
struct PasswordSignIn: Equatable {
    let userAuth: String
    /// "email" or "phone"
    let authType: String
}

/// The address Change password mails a reset link to, or nil when the account
/// has no password sign-in. The server's reset rewrites the account's email
/// and phone password sign-ins, `userAuths`, so the link goes to one of them,
/// an email before a phone. `userAuth` is only the identity the account was
/// created with: an account created with a wallet, a seed phrase or as a
/// guest that added an email and password later has none, so it was never
/// offered the reset, and a Google or Apple account has the provider's email,
/// which has no password. It is read only when there are no `userAuths` (an
/// older sdk or server).
func passwordResetUserAuth(userAuth: String?, authType: String, authTypes: [String], userAuths: [PasswordSignIn]) -> String? {
    for passwordAuthType in ["email", "phone"] {
        if let signIn = userAuths.first(where: { $0.authType == passwordAuthType && !$0.userAuth.isEmpty }) {
            return signIn.userAuth
        }
    }
    guard let userAuth, !userAuth.isEmpty else { return nil }
    let listed = authTypes.filter { !$0.isEmpty }
    // an old server sends no list, only the single auth type
    let hasPasswordSignIn = listed.isEmpty
        ? authType == "password"
        : listed.contains("email") || listed.contains("phone")
    return hasPasswordSignIn ? userAuth : nil
}

/// The account's password sign-ins, the server's `user_auths`.
func passwordSignIns(_ networkUser: SdkNetworkUser) -> [PasswordSignIn] {
    var signIns: [PasswordSignIn] = []
    if let list = networkUser.userAuths {
        for i in 0..<list.len() {
            if let signIn = list.get(i) {
                signIns.append(PasswordSignIn(userAuth: signIn.userAuth, authType: signIn.authType))
            }
        }
    }
    return signIns
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
        authTypes: authTypes,
        userAuths: passwordSignIns(networkUser)
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
