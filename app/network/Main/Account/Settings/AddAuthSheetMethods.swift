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

/// The wallets the Wallet method offers, in order: the same set as ur.io's
/// add sheet (ADD_SIGN_IN_WALLET_CHAINS) and every other app's. The server
/// adds either; a network holds one wallet.
enum AddAuthWalletChain: String, Hashable {
    case solana
    case bittensor
}

let addAuthWalletChains: [AddAuthWalletChain] = [.solana, .bittensor]

/// How the sheet runs an Apple or Google sign-in on this build: the way the
/// login screen does (LoginFullButtons). The native flow wherever the build
/// is configured for it (iOS and the macOS App Store build), the browser flow
/// (BrowserSso) in the direct-download build, otherwise not offered.
enum AddAuthProviderFlow: Equatable {
    case native
    case browser
    case unavailable
}

func addAuthProviderFlow(nativeConfigured: Bool, browserAvailable: Bool) -> AddAuthProviderFlow {
    if nativeConfigured {
        return .native
    }
    if browserAvailable {
        return .browser
    }
    return .unavailable
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

/// The AddAuth request for a Bittensor wallet proof, or nil when the proof
/// was not made for adding a sign-in method. Only a proof from the sheet's own
/// session (purpose "add") is added: a sign-in proof (login, create) or a
/// payout wallet proof (connect) belongs to another flow.
func addAuthBittensorArgs(_ proof: BittensorWalletProofInfo) -> SdkAddAuthArgs? {
    guard proof.purpose == SdkBittensorWalletPurposeAdd else {
        return nil
    }
    let walletAuth = SdkWalletAuthArgs()
    walletAuth.blockchain = SdkTAO
    walletAuth.publicKey = proof.address
    walletAuth.message = proof.message
    walletAuth.signature = proof.signature
    let args = SdkAddAuthArgs()
    args.walletAuth = walletAuth
    return args
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
