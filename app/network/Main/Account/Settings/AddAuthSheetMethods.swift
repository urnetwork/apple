//
//  AddAuthSheetMethods.swift
//  URnetwork
//

import URnetworkSdk

/// A sign-in method the add sheet offers. Apple, Google and wallet complete
/// through their own provider flow; email is sent with the sheet's Add button.
///
/// A seed phrase is not one: the server's AddAuth takes an email or phone with
/// a password, an SSO token, or a wallet signature, and answers a request with
/// none of them with "no auth method supplied". A seed phrase comes from
/// /auth/generate-seedphrase, which settings offers as Generate Seedphrase
/// and which shows the phrase to save.
enum AddAuthSheetMethod: String, Hashable {
    case apple
    case google
    case wallet
    case email
}

/// The methods the add sheet offers, in picker order.
func addAuthSheetMethods(appleAvailable: Bool, googleAvailable: Bool) -> [AddAuthSheetMethod] {
    var methods: [AddAuthSheetMethod] = []
    if appleAvailable {
        methods.append(.apple)
    }
    if googleAvailable {
        methods.append(.google)
    }
    methods.append(contentsOf: [.wallet, .email])
    return methods
}

/// The AddAuth request the Add button sends for `method`, or nil for a
/// method that completes through its own provider flow.
func addAuthButtonArgs(_ method: AddAuthSheetMethod, email: String, password: String) -> SdkAddAuthArgs? {
    switch method {
    case .email:
        let args = SdkAddAuthArgs()
        args.userAuth = email
        args.password = password
        return args
    case .apple, .google, .wallet:
        return nil
    }
}

/// Whether `args` name an auth method the server's AddAuth accepts: an
/// email or phone with a password, an SSO token with its type, or a wallet
/// signature (server model/network_user_model.go AddAuth). Anything else is
/// answered with "no auth method supplied".
func addAuthArgsSupplyMethod(_ args: SdkAddAuthArgs) -> Bool {
    if !args.userAuth.isEmpty && !args.password.isEmpty {
        return true
    }
    if !args.authJwt.isEmpty && !args.authJwtType.isEmpty {
        return true
    }
    return args.walletAuth != nil
}

/// Whether a sign-in added with `method` must be verified with a code before
/// it counts as added. AddAuth stores an email or phone unverified, and the
/// first sign-in with it would stop at a code anyway; the sheet asks for that
/// code right away. Apple and Google identities are verified by the provider,
/// and a wallet proves itself with its signature.
func addedSignInNeedsVerification(_ method: AddAuthSheetMethod) -> Bool {
    switch method {
    case .email:
        return true
    case .apple, .google, .wallet:
        return false
    }
}
