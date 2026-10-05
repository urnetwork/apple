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

    
    // When set, the wallet deep link onSignature routes here instead of the default multiplier claim flow
    var pendingAddAuthSignatureHandler: ((String, String) async -> Void)?
    
    // Challenge message to sign during wallet auth addition
    var pendingWalletAuthMessage: String?
    
    init() {
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

    /// Forgets the connected wallet's key and session without a wallet round
    /// trip. The Earnings payout flow only needs the public key it links;
    /// sign-in and add-sign-in-method then connect a wallet of their own
    /// instead of signing with this session.
    func forgetConnection() {
        clearConnectionState()
    }
    
    @discardableResult
    func connectSolflareWallet(onOpenFailed: (() -> Void)? = nil) -> Bool {
        prepareForWalletConnection()

        let queryStringResult = self.buildConnectQueryString(redirectLink: solflareConnectRedirectLink)
        
        guard case .success(let queryString) = queryStringResult else {
            print("Failed to build query string: \(queryStringResult)")
            return false
        }
        
        if let url = URL(string: "https://\(self.solflareHostname)/ul/v1/connect?\(queryString)") {
            return self.openURL(url) { success in
                if !success {
                    self.clearConnectionState()
                    onOpenFailed?()
                }
            }
        }

        return false
    }
    
    @discardableResult
    func connectPhantomWallet(onOpenFailed: (() -> Void)? = nil) -> Bool {
        prepareForWalletConnection()

        let queryStringResult = self.buildConnectQueryString(redirectLink: phantomConnectRedirectLink)
        
        guard case .success(let queryString) = queryStringResult else {
            print("Failed to build query string: \(queryStringResult)")
            return false
        }
        
        if let url = URL(string: "https://\(self.phantomHostname)/ul/v1/connect?\(queryString)") {
            return self.openURL(url) { success in
                if !success {
                    self.clearConnectionState()
                    onOpenFailed?()
                }
            }
        }

        return false
    }
    
    @discardableResult
    func signMessagePhantom(message: String, onOpenFailed: (() -> Void)? = nil) -> Bool {
        let queryStringResult = buildSignMessageQueryString(message: message, redirectLink: phantomSignMessageRedirectLink)
        
        guard case .success(let queryString) = queryStringResult else {
            print("Failed to build query string: \(queryStringResult)")
            return false
        }
        
        // Construct the URL string
        let urlString = "https://\(self.phantomHostname)/ul/v1/signMessage?\(queryString)"
        
        if let url = URL(string: urlString) {
            return self.openURL(url) { success in
                if !success {
                    onOpenFailed?()
                }
            }
        } else {
            print("Failed to create URL from: \(urlString)")
            return false
        }
    }
    
    @discardableResult
    func signMessageSolflare(message: String, onOpenFailed: (() -> Void)? = nil) -> Bool {
        let queryStringResult = buildSignMessageQueryString(message: message, redirectLink: solflareSignMessageRedirectLink)
        
        guard case .success(let queryString) = queryStringResult else {
            print("Failed to build query string: \(queryStringResult)")
            return false
        }
        
        if let url = URL(string: "https://\(self.solflareHostname)/ul/v1/signMessage?\(queryString)") {
            return self.openURL(url) { success in
                if !success {
                    onOpenFailed?()
                }
            }
        }
        
        return false
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
    
    func handleDeepLink(
        _ url: URL,
        onPublicKeyRetrieved: ((_ publicKey: String, _ wallet: ConnectedWalletProvider) -> Void)? = nil,
        onSignature: ((_ signature: String) -> Void)? = nil,
        onError: ((_ error: Error) -> Void)? = nil
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
        onError: ((_ error: Error) -> Void)? = nil
    ) {
        
        // First check for errors
        if let errorCode = queryItems.first(where: { $0.name == "errorCode" })?.value,
           let errorMessage = queryItems.first(where: { $0.name == "errorMessage" })?.value {
            print("Wallet signing error: Code \(errorCode) - \(errorMessage)")
            onError?(walletReturnError(code: errorCode, provider: connectedWalletProvider) ?? walletDeepLinkError("Wallet signing error: \(errorMessage)"))
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
            onError?(walletDeepLinkError("Missing required parameters for signature verification"))
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
                        print("Failed to decode base58 signature")
                        onError?(walletDeepLinkError("Failed to decode wallet signature"))
                    }
                    
                } catch {
                    print("Failed to decode signature response: \(error)")
                    if let responseString = String(data: decryptedData, encoding: .utf8) {
                        print("Raw response: \(responseString)")
                    }
                    onError?(error)
                }
            } else {
                print("Failed to decrypt signature data")
                onError?(walletDeepLinkError("Failed to decrypt wallet signature"))
            }
        } else {
            print("Failed to generate shared secret for signature verification")
            onError?(walletDeepLinkError("Failed to verify wallet signature"))
        }
    }
    
    private func handleConnect(
        queryItems: [URLQueryItem],
        connectedWalletProvider: ConnectedWalletProvider,
        onPublicKeyRetrieved: ((_ publicKey: String, _ wallet: ConnectedWalletProvider) -> Void)? = nil,
        onError: ((_ error: Error) -> Void)? = nil
    ) {
        if let errorCode = queryItems.first(where: { $0.name == "errorCode" })?.value,
           let errorMessage = queryItems.first(where: { $0.name == "errorMessage" })?.value {
            print("Wallet connect error: Code \(errorCode) - \(errorMessage)")
            clearConnectionState()
            onError?(walletReturnError(code: errorCode, provider: connectedWalletProvider) ?? walletDeepLinkError("Wallet connect error: \(errorMessage)"))
            return
        }

        let publicKeyParamKey = connectedWalletProvider == ConnectedWalletProvider.solflare ? "solflare_encryption_public_key" : "phantom_encryption_public_key"
        
        let params = queryParameters(from: queryItems)
        
        guard let walletEncryptionPublicKey = params[publicKeyParamKey],
              let nonce = params["nonce"],
              let data = params["data"],
              let keyPair = dappKeyPair else {
            clearConnectionState()
            onError?(walletDeepLinkError("Missing required parameters for wallet connection"))
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
                print("Decryption failed")
                clearConnectionState()
                onError?(walletDeepLinkError("Failed to decrypt wallet connection"))
            }
        } else {
            clearConnectionState()
            onError?(walletDeepLinkError("Failed to verify wallet connection"))
        }
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
    
    private func walletDeepLinkError(_ message: String) -> Error {
        NSError(domain: "ConnectWalletProviderViewModel", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// A failure the wallet or the ur.io bridge handed back, in this app's
    /// words when it knows the code; nil for any other code, whose own text
    /// the caller shows.
    private func walletReturnError(code: String, provider: ConnectedWalletProvider) -> Error? {
        SolanaWalletReturnError.text(code: code, provider: provider).map { WalletDeepLinkError.walletError($0) }
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
    case walletError(String)
}

enum ConnectedWalletProvider {
    case solflare
    case phantom
    case bittensor
}

/// This app's words for the error a Solana wallet hand-back carries: the ur.io
/// bridge page's codes on macOS (sdk SolanaWalletBridgeError*, sent next to
/// the page's English text), and on iOS the wallet apps' own 4001, a declined
/// request. Any other code (the page's invalid_request and wallet_error, a
/// wallet's other codes, the -1 of pages before the codes) has none: its own
/// text is shown.
enum SolanaWalletReturnError {
    /// Phantom's and Solflare's deep link code for a request the user declined
    static let walletUserRejectedCode = "4001"

    /// The words for `code`, with the wallet's product name where the text
    /// takes one; nil for a code this app does not know.
    static func text(code: String, provider: ConnectedWalletProvider) -> String? {
        let walletName = provider == .solflare ? "Solflare" : "Phantom"
        switch code {
        case SdkSolanaWalletBridgeErrorExtensionNotFound:
            return String(localized: "The \(walletName) extension was not found in this browser. Install it, then try again.")
        case SdkSolanaWalletBridgeErrorNoAccount:
            return String(localized: "Your \(walletName) wallet has no account to sign with. Add or connect an account in the wallet, then try again.")
        case SdkSolanaWalletBridgeErrorSessionNotFound:
            return String(localized: "The wallet connection wasn't found in this browser. Start again to reconnect your wallet.")
        case SdkSolanaWalletBridgeErrorUserRejected, walletUserRejectedCode:
            return String(localized: "The request was declined in your wallet. Start again and approve it to continue.")
        default:
            return nil
        }
    }
}

private struct SignMessagePayload: Encodable {
    let message: String
    let session: String
    let display: String
}
