//
//  ConnectWalletProviderViewModel.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2025/01/09.
//

import Foundation
import CryptoKit
import URnetworkSdk

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif


@MainActor
class ConnectWalletProviderViewModel: ObservableObject {
    @Published private(set) var connectedPublicKey: String?
    
    private var dappKeyPair: (privateKey: Curve25519.KeyAgreement.PrivateKey, publicKey: Curve25519.KeyAgreement.PublicKey)?
    private var sharedSecret: SymmetricKey?
    private var session: String?
    private let appURL = "https://ur.io"
    private var walletEncryptionPublicKey: String? = nil
    var connectedWalletProvider: ConnectedWalletProvider? = nil
    
    /// The scheme a hand-back's errorCode is read in, one of
    /// SdkSolanaWalletFailureSource*: on iOS the wallet apps' own deep link
    /// codes, on macOS the ur.io bridge page's codes (openURL hands the
    /// wallet's link to the bridge, which drives the browser extension).
    let walletReturnSource: String

    /**
     * Solflare
     */
    private let solflareHostname = "solflare.com"
    private let solflareConnectRedirectLink = "urnetwork://solflare-connect"
    private let solflareDisconnectRedirectLink = "urnetwork://solflare-disconnect"
    private let solflareSignMessageRedirectLink = "urnetwork://solflare-sign-message"
    
    /**
     * Phantom
     */
    private let phantomHostname = "phantom.app"
    private let phantomConnectRedirectLink = "urnetwork://phantom-connect"
    private let phantomDisconnectRedirectLink = "urnetwork://phantom-disconnect"
    private let phantomSignMessageRedirectLink = "urnetwork://phantom-sign-message"

    init() {
        #if canImport(UIKit)
        walletReturnSource = SdkSolanaWalletFailureSourceWalletApp
        #else
        walletReturnSource = SdkSolanaWalletFailureSourceBridge
        #endif
        self.createKeyPair()
    }

    /// Reads every hand-back in `walletReturnSource`'s scheme, whatever the
    /// platform (tests).
    init(walletReturnSource: String) {
        self.walletReturnSource = walletReturnSource
        self.createKeyPair()
    }
        
    private func createKeyPair() {
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        dappKeyPair = (privateKey, privateKey.publicKey)
    }

    private func clearConnectionState() {
        connectedPublicKey = nil
        sharedSecret = nil
        session = nil
        walletEncryptionPublicKey = nil
        connectedWalletProvider = nil
    }

    private func prepareForWalletConnection() {
        clearConnectionState()
        createKeyPair()
    }
    
    // Connecting and signing hand the request to the wallet: its app on iOS,
    // the ur.io bridge page in the browser on macOS (openURL). Each returns
    // false when the hand-off did not start. A request that could not be made
    // and a wallet that would not open, now or once the open completes, reach
    // `onOpenFailed` once, as the sdk's failure for it.

    @discardableResult
    func connectSolflareWallet(onOpenFailed: ((_ failure: SolanaWalletFailure) -> Void)? = nil) -> Bool {
        prepareForWalletConnection()

        let queryStringResult = self.buildConnectQueryString(redirectLink: solflareConnectRedirectLink)
        
        guard case .success(let queryString) = queryStringResult else {
            print("Failed to build query string: \(queryStringResult)")
            onOpenFailed?(.app(SdkSolanaWalletFailureWallet, provider: .solflare))
            return false
        }
        
        return openWallet(URL(string: "https://\(self.solflareHostname)/ul/v1/connect?\(queryString)"), provider: .solflare) { failure in
            self.clearConnectionState()
            onOpenFailed?(failure)
        }
    }
    
    @discardableResult
    func connectPhantomWallet(onOpenFailed: ((_ failure: SolanaWalletFailure) -> Void)? = nil) -> Bool {
        prepareForWalletConnection()

        let queryStringResult = self.buildConnectQueryString(redirectLink: phantomConnectRedirectLink)
        
        guard case .success(let queryString) = queryStringResult else {
            print("Failed to build query string: \(queryStringResult)")
            onOpenFailed?(.app(SdkSolanaWalletFailureWallet, provider: .phantom))
            return false
        }
        
        return openWallet(URL(string: "https://\(self.phantomHostname)/ul/v1/connect?\(queryString)"), provider: .phantom) { failure in
            self.clearConnectionState()
            onOpenFailed?(failure)
        }
    }
    
    @discardableResult
    func signMessagePhantom(message: String, attemptId: String? = nil, onOpenFailed: ((_ failure: SolanaWalletFailure) -> Void)? = nil) -> Bool {
        let queryStringResult = buildSignMessageQueryString(message: message, redirectLink: NetworkLoginWalletAttempt.redirectLink(phantomSignMessageRedirectLink, attemptId: attemptId))
        
        guard case .success(let queryString) = queryStringResult else {
            print("Failed to build query string: \(queryStringResult)")
            onOpenFailed?(.app(SdkSolanaWalletFailureWallet, provider: .phantom))
            return false
        }
        
        return openWallet(URL(string: "https://\(self.phantomHostname)/ul/v1/signMessage?\(queryString)"), provider: .phantom) { failure in
            onOpenFailed?(failure)
        }
    }
    
    @discardableResult
    func signMessageSolflare(message: String, attemptId: String? = nil, onOpenFailed: ((_ failure: SolanaWalletFailure) -> Void)? = nil) -> Bool {
        let queryStringResult = buildSignMessageQueryString(message: message, redirectLink: NetworkLoginWalletAttempt.redirectLink(solflareSignMessageRedirectLink, attemptId: attemptId))
        
        guard case .success(let queryString) = queryStringResult else {
            print("Failed to build query string: \(queryStringResult)")
            onOpenFailed?(.app(SdkSolanaWalletFailureWallet, provider: .solflare))
            return false
        }
        
        return openWallet(URL(string: "https://\(self.solflareHostname)/ul/v1/signMessage?\(queryString)"), provider: .solflare) { failure in
            onOpenFailed?(failure)
        }
    }

    /// Opens the wallet's `url`. A link that could not be made is the
    /// wallet's generic failure (wallet_error), a wallet that would not open
    /// wallet_app_not_found; either reaches `onOpenFailed` once. False when
    /// the hand-off did not start.
    private func openWallet(_ url: URL?, provider: ConnectedWalletProvider, onOpenFailed: @escaping (_ failure: SolanaWalletFailure) -> Void) -> Bool {
        guard let url else {
            print("Failed to make the \(provider) wallet link")
            onOpenFailed(.app(SdkSolanaWalletFailureWallet, provider: provider))
            return false
        }
        return openURL(url) { success in
            if !success {
                print("The \(provider) wallet would not open")
                onOpenFailed(.app(SdkSolanaWalletFailureWalletAppNotFound, provider: provider))
            }
        }
    }
    
    /**
     * For reference: https://docs.phantom.com/phantom-deeplinks/provider-methods/signmessage
     */
    private func buildSignMessageQueryString(message: String, redirectLink: String) -> Result<String, WalletDeepLinkError> {
        guard let keyPair = self.dappKeyPair,
              let session = self.session,
              let walletEncryptionPublicKey = self.walletEncryptionPublicKey else {
            print("Missing params: keyPair=\(dappKeyPair != nil), session=\(session != nil), walletKey=\(walletEncryptionPublicKey != nil)")
            return .failure(WalletDeepLinkError.missingParams)
        }
        
        // Base58 encode the message first
        guard let messageData = message.data(using: .utf8) else {
            print("Failed to convert message to data")
            return .failure(WalletDeepLinkError.failedCreatingPayload)
        }
        
         let messageBase58 = SdkEncodeBase58(messageData)
        
        // Create payload object
        let payload = SignMessagePayload(
            message: messageBase58,
            session: session,
            display: "utf8"
        )
        
        // Convert payload to JSON data
        guard let payloadData = try? JSONEncoder().encode(payload) else {
            print("Failed to encode payload to JSON")
            return .failure(WalletDeepLinkError.failedCreatingPayload)
        }
        
        // Generate shared secret for encryption
        guard let sharedSecret = generateSharedSecret(
            privateKey: keyPair.privateKey,
            walletEncryptionPublicKey: walletEncryptionPublicKey
        ) else {
            print("Failed to generate shared secret")
            return .failure(WalletDeepLinkError.failedCreatingPayload)
        }
        
        // Generate nonce
        let nonce = SdkGenerateNonce()
        
        // Convert shared secret to base58
        let sharedSecretBase58 = SdkEncodeBase58(sharedSecret)
        
        var error: NSError?
        
        let encryptedData = SdkEncryptData(payloadData, nonce, sharedSecretBase58, &error)
        
        if let error = error {
            print("Encryption failed with error: \(error.localizedDescription), code: \(error.code)")
            print("Error domain: \(error.domain), userInfo: \(error.userInfo)")
            return .failure(WalletDeepLinkError.failedCreatingPayload)
        }
        
        guard !encryptedData.isEmpty else {
            print("Encryption produced empty result")
            return .failure(WalletDeepLinkError.failedCreatingPayload)
        }
        
        // Build the params with encrypted payload
        let params: [String: String] = [
            "dapp_encryption_public_key": SdkEncodeBase58(keyPair.publicKey.rawRepresentation),
            "cluster": "mainnet-beta",
            "nonce": nonce,
            "redirect_link": redirectLink,
            "payload": encryptedData
        ]
        
        // Generate query string
        let queryItems = params.map { key, value in
            // URL encode each value
            guard let encodedValue = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
                return "\(key)=\(value)"
            }
            return "\(key)=\(encodedValue)"
        }
        
        let queryString = queryItems.joined(separator: "&")

        return .success(queryString)
    }
    
    private func buildConnectQueryString(redirectLink: String) -> Result<String, WalletDeepLinkError> {
        guard let keyPair = dappKeyPair else { return .failure(WalletDeepLinkError.missingDappKeyPair) }
        
        let params = [
            "dapp_encryption_public_key": SdkEncodeBase58(keyPair.publicKey.rawRepresentation),
            "cluster": "mainnet-beta",
            // TODO: app url should be `A url used to fetch app metadata (i.e. title, icon) using the same properties found in Displaying Your App. URL-encoded.` The app URL should contain https://docs.phantom.com/best-practices/displaying-your-app
            "app_url": appURL,
            "redirect_link": redirectLink
        ]
        
        let queryString = params.map { key, value in
            guard let encodedValue = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
                return "\(key)=\(value)"
            }
            return "\(key)=\(encodedValue)"
        }.joined(separator: "&")

        return .success(queryString)
    }
    
    /// A Phantom or Solflare hand-back: the connection, or the signature. A
    /// failure, handed back or found reading the hand-back, reaches `onError`
    /// as the sdk's failure for it.
    func handleDeepLink(
        _ url: URL,
        onPublicKeyRetrieved: ((_ publicKey: String, _ wallet: ConnectedWalletProvider) -> Void)? = nil,
        onSignature: ((_ signature: String) -> Void)? = nil,
        onError: ((_ failure: SolanaWalletFailure) -> Void)? = nil
    ) {

        // todo - handle disconnect

        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else {
            print("no match for components.host")
            return
        }

        // a Bittensor bridge hand-back belongs to the SDK wallet-connect
        // session of the screen that opened it (BittensorWalletConnector)
        if components.host == "bittensor-sign-message" {
            return
        }

        guard components.host == "solflare-connect" || components.host == "phantom-connect" || components.host == "phantom-sign-message" || components.host == "solflare-sign-message" else {
            print("no match for components.host")
            return
        }
        
        let host = components.host
        
        let connectedWalletProvider = (host == "solflare-connect" || host == "solflare-sign-message") ? ConnectedWalletProvider.solflare : ConnectedWalletProvider.phantom
        
        self.connectedWalletProvider = connectedWalletProvider
        let isConnecting = host == "solflare-connect" || host == "phantom-connect"
        
        if isConnecting {
            self.handleConnect(
                queryItems: queryItems,
                connectedWalletProvider: connectedWalletProvider,
                onPublicKeyRetrieved: onPublicKeyRetrieved,
                onError: onError
            )
        }
        
        let isSigningMessage = host == "phantom-sign-message" || host == "solflare-sign-message"
        
        if isSigningMessage {
            self.handleSignMessage(
                queryItems: queryItems,
                connectedWalletProvider: connectedWalletProvider,
                onSignature: onSignature,
                onError: onError
            )
        }
        
    }
    
    private func handleSignMessage(
        queryItems: [URLQueryItem],
        connectedWalletProvider: ConnectedWalletProvider,
        onSignature: ((_ signature: String) -> Void)? = nil,
        onError: ((_ failure: SolanaWalletFailure) -> Void)? = nil
    ) {
        
        // First check for errors
        if let failure = walletReturnFailure(queryItems: queryItems, provider: connectedWalletProvider) {
            if failure.failure == SdkSolanaWalletFailureSessionNotFound {
                // the browser lost the connect step's key, so starting again
                // must connect the wallet again rather than sign at once
                clearConnectionState()
            }
            onError?(failure)
            return
        }
        
        let params = queryParameters(from: queryItems)
        
        guard let nonce = params["nonce"],
            let data = params["data"],
            let keyPair = dappKeyPair,
            let walletEncryptionPublicKey = self.walletEncryptionPublicKey else {
            print("Missing required parameters for signature verification")
            print("nonce: \(params["nonce"] != nil)")
            print("data: \(params["data"] != nil)")
            print("keyPair: \(dappKeyPair != nil)")
            print("walletEncryptionPublicKey: \(self.walletEncryptionPublicKey != nil)")
            onError?(unreadableReturn("missing signature parameters", provider: connectedWalletProvider))
            return
        }
              
        if let sharedSecret = generateSharedSecret(
            privateKey: keyPair.privateKey,
            walletEncryptionPublicKey: walletEncryptionPublicKey
        ) {
            let sharedSecretBase58 = SdkEncodeBase58(sharedSecret)
            
            if let decryptedData = SdkDecryptData(data, nonce, sharedSecretBase58, nil) {
                
                do {
                    let json = try JSONDecoder().decode(SignatureApproveResponse.self, from: decryptedData)
                    
                    // Convert base58 signature to base64
                    if let signatureData = SdkDecodeBase58(json.signature, nil) {
                        let base64Signature = signatureData.base64EncodedString()
                        
                        if let callback = onSignature {
                            callback(base64Signature)  // Send base64 signature to the callback
                        }
                    } else {
                        onError?(unreadableReturn("the signature is not base58", provider: connectedWalletProvider))
                    }
                    
                } catch {
                    print("Failed to decode signature response: \(error)")
                    if let responseString = String(data: decryptedData, encoding: .utf8) {
                        print("Raw response: \(responseString)")
                    }
                    onError?(unreadableReturn("the signature response does not decode", provider: connectedWalletProvider))
                }
            } else {
                onError?(unreadableReturn("the signature does not decrypt", provider: connectedWalletProvider))
            }
        } else {
            onError?(unreadableReturn("no shared secret for the signature", provider: connectedWalletProvider))
        }
    }
    
    private func handleConnect(
        queryItems: [URLQueryItem],
        connectedWalletProvider: ConnectedWalletProvider,
        onPublicKeyRetrieved: ((_ publicKey: String, _ wallet: ConnectedWalletProvider) -> Void)? = nil,
        onError: ((_ failure: SolanaWalletFailure) -> Void)? = nil
    ) {
        if let failure = walletReturnFailure(queryItems: queryItems, provider: connectedWalletProvider) {
            clearConnectionState()
            onError?(failure)
            return
        }

        let publicKeyParamKey = connectedWalletProvider == ConnectedWalletProvider.solflare ? "solflare_encryption_public_key" : "phantom_encryption_public_key"
        
        let params = queryParameters(from: queryItems)
        
        guard let walletEncryptionPublicKey = params[publicKeyParamKey],
              let nonce = params["nonce"],
              let data = params["data"],
              let keyPair = dappKeyPair else {
            clearConnectionState()
            onError?(unreadableReturn("missing connection parameters", provider: connectedWalletProvider))
            return
        }
              
        if let sharedSecret = generateSharedSecret(
            privateKey: keyPair.privateKey,
            walletEncryptionPublicKey: walletEncryptionPublicKey
        ) {
            let sharedSecretBase58 = SdkEncodeBase58(sharedSecret)
            
            if let decryptedData = SdkDecryptData(data, nonce, sharedSecretBase58, nil),
               let json = try? JSONDecoder().decode(ConnectApproveResponse.self, from: decryptedData) {
                self.walletEncryptionPublicKey = walletEncryptionPublicKey
                self.connectedPublicKey = json.public_key
                self.session = json.session
                self.connectedWalletProvider = connectedWalletProvider
                
                if let callback = onPublicKeyRetrieved {
                    callback(json.public_key, connectedWalletProvider)
                }
                
            } else {
                clearConnectionState()
                onError?(unreadableReturn("the connection does not decrypt or decode", provider: connectedWalletProvider))
            }
        } else {
            clearConnectionState()
            onError?(unreadableReturn("no shared secret for the connection", provider: connectedWalletProvider))
        }
    }

    /// The failure a hand-back carries in place of its answer
    /// (?errorCode&errorMessage), read by the sdk in this platform's scheme
    /// (walletReturnSource); nil for a hand-back without one. The wallet's or
    /// the bridge page's own text is only logged, never shown.
    private func walletReturnFailure(queryItems: [URLQueryItem], provider: ConnectedWalletProvider) -> SolanaWalletFailure? {
        guard let errorCode = queryItems.first(where: { $0.name == "errorCode" })?.value else {
            return nil
        }
        let errorMessage = queryItems.first(where: { $0.name == "errorMessage" })?.value ?? ""
        let failure = SolanaWalletFailure(source: walletReturnSource, code: errorCode, provider: provider)
        print("Wallet hand-back from \(provider): \(walletReturnSource) code \(errorCode) is \(failure.failure): \(errorMessage)")
        return failure
    }

    /// A hand-back this app could not read (missing parameters, a key or an
    /// answer that does not decrypt or decode): the wallet's generic failure.
    private func unreadableReturn(_ reason: String, provider: ConnectedWalletProvider) -> SolanaWalletFailure {
        print("Wallet hand-back from \(provider) unreadable: \(reason)")
        return .app(SdkSolanaWalletFailureWallet, provider: provider)
    }

    private func queryParameters(from queryItems: [URLQueryItem]) -> [String: String] {
        queryItems.reduce(into: [:]) { params, item in
            guard params[item.name] == nil, let value = item.value else {
                return
            }

            params[item.name] = value
        }
    }
    
    private func generateSharedSecret(privateKey: Curve25519.KeyAgreement.PrivateKey, walletEncryptionPublicKey: String) -> Data? {
        
        guard let walletPublicKeyData = SdkDecodeBase58(walletEncryptionPublicKey, nil) else {
            print("Failed to decode wallet encryption public key")
            return nil
        }
        
        // Use SdkGenerateSharedSecret instead of CryptoKit
        return SdkGenerateSharedSecret(
            privateKey.rawRepresentation,
            walletPublicKeyData,
            nil
        )
    }
    
    /**
     * Disconnect is currently not used or handled in handleDeepLink
     */
    private func disconnect(connectedWalletProvider: ConnectedWalletProvider) {

        let redirectLink = connectedWalletProvider == .phantom ? self.phantomDisconnectRedirectLink : self.solflareDisconnectRedirectLink

        guard case .success(let queryString) = buildDisconnectQueryString(redirectLink: redirectLink) else {
            return
        }

        let hostName = connectedWalletProvider == .phantom ? phantomHostname : solflareHostname

        if let url = URL(string: "https://\(hostName)/ul/v1/disconnect?\(queryString)") {
            self.openURL(url)
        }

    }
    
    private func buildDisconnectQueryString(redirectLink: String) -> Result<String, WalletDeepLinkError> {
        guard let keyPair = self.dappKeyPair, let session = self.session else { return .failure(WalletDeepLinkError.missingParams) }
        guard case .success(let nonce) = self.generateNonce() else {
            return .failure(WalletDeepLinkError.failedGeneratingNonce)
        }
        
        let payload = DisconnectPayload(session: session)
        guard let jsonData = try? JSONEncoder().encode(payload),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return .failure(WalletDeepLinkError.failedCreatingPayload)
        }
        
        let params = [
            "dapp_encryption_public_key": SdkEncodeBase58(keyPair.publicKey.rawRepresentation),
            "nonce": nonce,
            "redirect_link": redirectLink,
            "payload": jsonString
        ]
        
        let queryString = params.map { key, value in
            guard let encodedValue = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
                return "\(key)=\(value)"
            }
            return "\(key)=\(encodedValue)"
        }.joined(separator: "&")
        return .success(queryString)
    }
    
    /**
     * Used for created a disconnect nonce
     */
    private func generateNonce() -> Result<String, WalletDeepLinkError> {
        var randomBytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
        guard status == errSecSuccess else {
            return .failure(.failedGeneratingNonce)
        }
        return .success(SdkEncodeBase58(Data(randomBytes)))
    }

    #if canImport(AppKit)
    private func nativeWalletURL(from universalLink: URL) -> URL? {
        guard var components = URLComponents(url: universalLink, resolvingAgainstBaseURL: false) else {
            return nil
        }

        let walletScheme: String
        switch components.host {
        case phantomHostname:
            walletScheme = "phantom"
        case solflareHostname:
            walletScheme = "solflare"
        default:
            return nil
        }

        guard components.path.hasPrefix("/ul/") else {
            return nil
        }

        components.scheme = walletScheme
        components.host = "ul"
        components.path = String(components.path.dropFirst("/ul".count))
        return components.url
    }

    /**
     * Rewrites a Phantom/Solflare universal link into the ur.io/wallet-connect
     * browser-bridge URL. Desktop wallets are browser extensions rather than
     * deeplink apps, so the app opens this page in the browser; it drives the
     * extension and returns via the urnetwork:// scheme with the same envelope.
     */
    private func webConnectURL(from universalLink: URL) -> URL? {
        guard let components = URLComponents(url: universalLink, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let providerName: String
        switch components.host {
        case phantomHostname: providerName = "phantom"
        case solflareHostname: providerName = "solflare"
        default: return nil
        }
        let method: String
        if components.path.hasSuffix("/connect") {
            method = "connect"
        } else if components.path.hasSuffix("/signMessage") {
            method = "signMessage"
        } else {
            // disconnect and other ops aren't bridged
            return nil
        }
        var webComponents = URLComponents()
        webComponents.scheme = "https"
        webComponents.host = "ur.io"
        webComponents.path = "/wallet-connect"
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "method", value: method))
        items.append(URLQueryItem(name: "provider", value: providerName))
        webComponents.queryItems = items
        return webComponents.url
    }
    #endif

    @discardableResult
    func openURL(_ url: URL, completion: ((Bool) -> Void)? = nil) -> Bool {
        #if canImport(UIKit)
        UIApplication.shared.open(url, options: [.universalLinksOnly: true]) { success in
            if success {
                DispatchQueue.main.async {
                    completion?(true)
                }
                return
            }

            // the universal link wasn't claimed by an installed wallet app
            // (e.g. the wallet's app-site association hasn't resolved yet) —
            // fall back to opening the link normally so it still reaches the
            // wallet (or the browser) instead of hard-failing
            UIApplication.shared.open(url, options: [:]) { fallbackSuccess in
                DispatchQueue.main.async {
                    completion?(fallbackSuccess)
                }
            }
        }
        return true
        #elseif canImport(AppKit)
        // desktop Phantom/Solflare are browser extensions, not URL-scheme apps.
        // route the wallet universal link through the ur.io/wallet-connect
        // browser bridge, which drives the extension and returns to the app via
        // the urnetwork:// scheme with the same encrypted envelope.
        if let webURL = webConnectURL(from: url) {
            let success = NSWorkspace.shared.open(webURL)
            completion?(success)
            return success
        }

        // non-wallet links fall back to opening directly
        let success = NSWorkspace.shared.open(url)
        completion?(success)
        return success
        #else
        completion?(false)
        return false
        #endif
    }
    
    func isWalletAppInstalled(_ walletType: ConnectedWalletProvider) -> Bool {
        #if canImport(AppKit)
        // desktop wallets are browser extensions we can't probe here; the
        // ur.io/wallet-connect bridge detects them, so always offer the option
        return true
        #elseif canImport(UIKit)
        let scheme: String
        switch walletType {
        case .phantom:
            scheme = "phantom://"
        case .solflare:
            scheme = "solflare://"
        case .bittensor:
            // bittensor connects through the ur.io/wallet-connect bridge, not a
            // native app scheme, so there's nothing to probe — always offer it
            return true
        }
        guard let url = URL(string: scheme) else { return false }
        return UIApplication.shared.canOpenURL(url)
        #else
        return false
        #endif
    }
    
}

private struct ConnectApproveResponse: Codable {
    let public_key: String
    let session: String
}

private struct SignatureApproveResponse: Codable {
    let signature: String
}

private struct DisconnectPayload: Encodable {
    let session: String
}

enum WalletDeepLinkError: Error {
    case missingDappKeyPair
    case failedCreatingPayload
    case failedGeneratingNonce
    case missingParams
    case invalidParameters
}

enum ConnectedWalletProvider {
    case solflare
    case phantom
    case bittensor
}

/// Why a Solana wallet sign-in failed (signing in, the second signature that
/// creates a network, adding a sign-in method), read by the sdk
/// (SdkSolanaWalletFailureFor) the same way on every app: the failure, and
/// the localizations store key of the message every app shows for it. The
/// app only picks the scheme of the code (the ur.io bridge page's on macOS,
/// the wallet apps' own on iOS, or a failure it found itself) and displays
/// the message. A wallet's or the bridge page's own text is never shown.
struct SolanaWalletFailure: Error, Equatable {
    /// one of SdkSolanaWalletFailure*
    let failure: String
    /// one of SdkSolanaWalletFailureMessage*
    let messageKey: String
    /// the message's argument, a wallet product name; "" when it takes none
    let walletName: String

    /// The failure `code` names in the scheme of `source`, one of
    /// SdkSolanaWalletFailureSource*. `provider` is the wallet the user chose,
    /// which the sdk names; nil when the app does not know which answered.
    init(source: String, code: String, provider: ConnectedWalletProvider?) {
        let walletId: String
        switch provider {
        case .phantom:
            walletId = "phantom"
        case .solflare:
            walletId = "solflare"
        case .bittensor, nil:
            walletId = ""
        }
        let classified = SdkSolanaWalletFailureFor(source, code, walletId)
        // the sdk answers every source and code; a nil from the binding
        // reads as the generic failure
        failure = classified?.failure ?? SdkSolanaWalletFailureWallet
        messageKey = classified?.messageKey ?? SdkSolanaWalletFailureMessageWallet
        walletName = classified?.walletName ?? ""
    }

    /// A failure the app found itself, `code` one of SdkSolanaWalletFailure*.
    static func app(_ code: String, provider: ConnectedWalletProvider?) -> SolanaWalletFailure {
        SolanaWalletFailure(source: SdkSolanaWalletFailureSourceApp, code: code, provider: provider)
    }

    /// The message, in the user's language.
    var message: String {
        Self.message(messageKey: messageKey, walletName: walletName)
    }

    /// The text of each store key the sdk answers, in the user's language,
    /// with the wallet's name where it takes one: the one place an app
    /// screen gets a Solana sign-in failure's words.
    static func message(messageKey: String, walletName: String) -> String {
        switch messageKey {
        case SdkSolanaWalletFailureMessageUserRejected:
            return String(localized: "The request was declined in your wallet. Start again and approve it to continue.")
        case SdkSolanaWalletFailureMessageNoWallet:
            return String(localized: "No Solana wallets were found installed on this device. Please install a wallet and try again.")
        case SdkSolanaWalletFailureMessageWalletAppNotFound:
            return String(localized: "Couldn't open wallet. Please install it and try again.")
        case SdkSolanaWalletFailureMessageExtensionNotFound:
            return String(localized: "The \(walletName) extension was not found in this browser. Install it, then try again.")
        case SdkSolanaWalletFailureMessageNoAccount:
            return String(localized: "Your \(walletName) wallet has no account to sign with. Add or connect an account in the wallet, then try again.")
        case SdkSolanaWalletFailureMessageSessionNotFound:
            return String(localized: "The wallet connection wasn't found in this browser. Start again to reconnect your wallet.")
        case SdkSolanaWalletFailureMessageWallet:
            fallthrough
        default:
            // the wallet's generic failure, which a key this build does not
            // know reads as too; it names Solana when the wallet is unknown
            let name = walletName.isEmpty ? "Solana" : walletName
            return String(localized: "Your \(name) wallet couldn't finish the request. Check the wallet, then try again.")
        }
    }
}

private struct SignMessagePayload: Encodable {
    let message: String
    let session: String
    let display: String
}
