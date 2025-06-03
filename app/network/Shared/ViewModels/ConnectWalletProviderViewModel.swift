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
    
    let welcomeMessage = "Welcome to URnetwork"
    let claimSeekerTokenMessage = "Claim point multiplier by holding Seeker Pre-order or Saga Genesis token"
    
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
        self.createKeyPair()
    }
        
    private func createKeyPair() {
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        dappKeyPair = (privateKey, privateKey.publicKey)
    }
    
    func connectSolflareWallet() {
        let queryStringResult = self.buildConnectQueryString(redirectLink: solflareConnectRedirectLink)
        
        guard case .success(let queryString) = queryStringResult else {
            print("Failed to build query string: \(queryStringResult)")
            return
        }
        
        if let url = URL(string: "https://\(self.solflareHostname)/ul/v1/connect?\(queryString)") {
            
            self.openURL(url)
            
        }
    }
    
    func connectPhantomWallet() {
        let queryStringResult = self.buildConnectQueryString(redirectLink: phantomConnectRedirectLink)
        
        guard case .success(let queryString) = queryStringResult else {
            print("Failed to build query string: \(queryStringResult)")
            return
        }
        
        if let url = URL(string: "https://\(self.phantomHostname)/ul/v1/connect?\(queryString)") {
            self.openURL(url)
        }
    }
    
    func signMessagePhantom(message: String) {
        let queryStringResult = buildSignMessageQueryString(message: message, redirectLink: phantomSignMessageRedirectLink)
        
        guard case .success(let queryString) = queryStringResult else {
            print("Failed to build query string: \(queryStringResult)")
            return
        }
        
        // Construct the URL string
        let urlString = "https://\(self.phantomHostname)/ul/v1/signMessage?\(queryString)"
        
        if let url = URL(string: urlString) {
            self.openURL(url)
        } else {
            print("Failed to create URL from: \(urlString)")
        }
    }
    
    func signMessageSolflare(message: String) {
        let queryStringResult = buildSignMessageQueryString(message: message, redirectLink: solflareSignMessageRedirectLink)
        
        guard case .success(let queryString) = queryStringResult else {
            print("Failed to build query string: \(queryStringResult)")
            return
        }
        
        if let url = URL(string: "https://\(self.solflareHostname)/ul/v1/signMessage?\(queryString)") {
            self.openURL(url)
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
        
        let queryString = params.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        
        return .success(queryString)
    }
    
    func handleDeepLink(
        _ url: URL,
        onPublicKeyRetrieved: ((_ publicKey: String, _ wallet: ConnectedWalletProvider) -> Void)? = nil,
        onSignature: ((_ signature: String) -> Void)? = nil
    ) {
        
        // todo - handle disconnect

        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems,
              components.host == "solflare-connect" || components.host == "phantom-connect" || components.host == "phantom-sign-message" || components.host == "solflare-sign-message" else {
            print("no match for components.host")
            return
        }
        
        let host = components.host
        
        let connectedWalletProvider = (host == "solflare-connect") ? ConnectedWalletProvider.solflare : ConnectedWalletProvider.phantom
        
        let isConnecting = host == "solflare-connect" || host == "phantom-connect"
        
        if isConnecting {
            self.handleConnect(
                queryItems: queryItems,
                connectedWalletProvider: connectedWalletProvider,
                onPublicKeyRetrieved: onPublicKeyRetrieved
            )
        }
        
        let isSigningMessage = host == "phantom-sign-message" || host == "solflare-sign-message"
        
        if isSigningMessage {
            self.handleSignMessage(
                queryItems: queryItems,
                connectedWalletProvider: connectedWalletProvider,
                onSignature: onSignature
            )
        }
        
    }
    
    private func handleSignMessage(
        queryItems: [URLQueryItem],
        connectedWalletProvider: ConnectedWalletProvider,
        onSignature: ((_ signature: String) -> Void)? = nil
    ) {
        
        // First check for errors
        if let errorCode = queryItems.first(where: { $0.name == "errorCode" })?.value,
           let errorMessage = queryItems.first(where: { $0.name == "errorMessage" })?.value {
            print("Wallet signing error: Code \(errorCode) - \(errorMessage)")
            return
        }
        
        let params: [String: String] = Dictionary(uniqueKeysWithValues: queryItems.compactMap { item in
            guard let value = item.value else { return nil }
            return (item.name, value)
        })
        
        guard let nonce = params["nonce"],
            let data = params["data"],
            let keyPair = dappKeyPair,
            let walletEncryptionPublicKey = self.walletEncryptionPublicKey else {
            print("Missing required parameters for signature verification")
            print("nonce: \(params["nonce"] != nil)")
            print("data: \(params["data"] != nil)")
            print("keyPair: \(dappKeyPair != nil)")
            print("walletEncryptionPublicKey: \(self.walletEncryptionPublicKey != nil)")
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
                    }
                    
                } catch {
                    print("Failed to decode signature response: \(error)")
                    if let responseString = String(data: decryptedData, encoding: .utf8) {
                        print("Raw response: \(responseString)")
                    }
                }
            } else {
                print("Failed to decrypt signature data")
            }
        } else {
            print("Failed to generate shared secret for signature verification")
        }
    }
    
    private func handleConnect(
        queryItems: [URLQueryItem],
        connectedWalletProvider: ConnectedWalletProvider,
        onPublicKeyRetrieved: ((_ publicKey: String, _ wallet: ConnectedWalletProvider) -> Void)? = nil
    ) {
        let publicKeyParamKey = connectedWalletProvider == ConnectedWalletProvider.solflare ? "solflare_encryption_public_key" : "phantom_encryption_public_key"
        
        let params: [String: String] = Dictionary(uniqueKeysWithValues: queryItems.compactMap { item in
            guard let value = item.value else { return nil }
            return (item.name, value)
        })
        
        guard let walletEncryptionPublicKey = params[publicKeyParamKey],
              let nonce = params["nonce"],
              let data = params["data"],
              let keyPair = dappKeyPair else { return }
        
        self.walletEncryptionPublicKey = walletEncryptionPublicKey
              
        if let sharedSecret = generateSharedSecret(
            privateKey: keyPair.privateKey,
            walletEncryptionPublicKey: walletEncryptionPublicKey
        ) {
            let sharedSecretBase58 = SdkEncodeBase58(sharedSecret)
            
            if let decryptedData = SdkDecryptData(data, nonce, sharedSecretBase58, nil),
               let json = try? JSONDecoder().decode(ConnectApproveResponse.self, from: decryptedData) {
                self.connectedPublicKey = json.public_key
                self.session = json.session
                self.connectedWalletProvider = connectedWalletProvider
                
                if let callback = onPublicKeyRetrieved {
                    callback(json.public_key, connectedWalletProvider)
                }
                
            } else {
                print("Decryption failed")
            }
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
        
        let queryString = buildDisconnectQueryString(redirectLink: redirectLink)
        
        let hostName = connectedWalletProvider == .phantom ? phantomHostname : solflareHostname
        
        if let url = URL(string: "https://\(hostName)/ul/v1/disconnect?\(queryString)") {
            self.openURL(url)
        }
        
    }
    
    private func buildDisconnectQueryString(redirectLink: String) -> Result<String, WalletDeepLinkError> {
        guard let keyPair = self.dappKeyPair, let session = self.session else { return .failure(WalletDeepLinkError.missingParams) }
        let nonce = self.generateNonce()
        
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
        
        let queryString = params.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        return .success(queryString)
    }
    
    /**
     * Used for created a disconnect nonce
     */
    private func generateNonce() -> String {
        let randomBytes = Array<UInt8>.init(repeating: 0, count: 32)
        SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, UnsafeMutableRawPointer(mutating: randomBytes))
        return SdkEncodeBase58(Data(randomBytes))
    }
    
    func openURL(_ url: URL) {
        #if canImport(UIKit)
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
        #elseif canImport(AppKit)
        NSWorkspace.shared.open(url)
        #endif
    }
    
    func isWalletAppInstalled(_ walletType: ConnectedWalletProvider) -> Bool {
        let scheme: String
        switch walletType {
        case .phantom:
            scheme = "phantom://"
        case .solflare:
            scheme = "solflare://"
        }
        
        guard let url = URL(string: scheme) else { return false }
        
        #if canImport(UIKit)
        return UIApplication.shared.canOpenURL(url)
        #elseif canImport(AppKit)
        // On macOS, we check if any app can handle the URL scheme
        return NSWorkspace.shared.urlForApplication(toOpen: url) != nil
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
    case missingParams
    case invalidParameters
}

enum ConnectedWalletProvider {
    case solflare
    case phantom
}

private struct SignMessagePayload: Encodable {
    let message: String
    let session: String
    let display: String
}
