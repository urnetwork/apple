import CryptoKit
import Foundation
import URnetworkSdk

/// Solana's signature callback has no attempt identifier. Admit it only when
/// it proves the exact challenge held by the current request, without rebinding
/// an unverified return to the latest pending slot.
enum NetworkLoginWalletProof {
    static func matches(message: String, signature: String, publicKey: String) -> Bool {
        guard !message.isEmpty, let signatureBytes = Data(base64Encoded: signature),
              let keyBytes = SdkDecodeBase58(publicKey, nil),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyBytes) else { return false }
        return key.isValidSignature(signatureBytes, for: Data(message.utf8))
    }
}
