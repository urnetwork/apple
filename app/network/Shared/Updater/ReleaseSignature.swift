//
//  ReleaseSignature.swift
//  URnetwork
//
//  The second, release-level signature check of the direct-download
//  updater (staged: `requireUpdateSignature` is false until every stable
//  release carries the files).
//
//  A release may attach
//    SHA256SUMS      lines `<64 hex>  <asset name>`
//    SHA256SUMS.sig  base64 (standard alphabet) ed25519 signature over the
//                    exact SHA256SUMS bytes, followed by a newline
//  signed by the release key whose public half is embedded below. When the
//  .sig is present the signature must verify and the downloaded file's
//  SHA-256 must match its SHA256SUMS line, or the update is refused. When
//  it is absent the update is refused only if `requireUpdateSignature`.
//  This is in addition to the asset digest and the code-signing /
//  notarization checks, never instead of them.
//
//  Pure: the public key is injectable so tests sign with their own key.
//

import Foundation
import CryptoKit

enum ReleaseSignature {

    static let sumsAssetName = "SHA256SUMS"
    static let signatureAssetName = "SHA256SUMS.sig"

    /// Staged rollout switch. Flip to true once releases always sign.
    static let requireUpdateSignature = false

    /// The release signing key (raw 32-byte ed25519, base64).
    static let publicKeyBase64 = "Qm4V/UTZcuIRMFJuAzDhxf2CK6ycwxF0HFOcFhXBIYQ="

    static var publicKey: Curve25519.Signing.PublicKey {
        // a constant; a malformed literal is a programming error
        try! Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: publicKeyBase64)!)
    }

    enum Outcome: Equatable {
        /// Signature valid and the file's hash matches its signed line.
        case verified
        /// No signature published and none required: continue (log it).
        case unsigned
        /// Refuse the update, with the reason.
        case refused(String)

        var allowsInstall: Bool {
            switch self {
            case .verified, .unsigned: return true
            case .refused: return false
            }
        }
    }

    /// Decide the release-signature check.
    /// - sums: the SHA256SUMS bytes, nil when the release lacks the asset.
    /// - signature: the SHA256SUMS.sig bytes, nil when the release lacks it.
    /// - assetName: the downloaded file's name as it appears in SHA256SUMS.
    /// - actualHex: the downloaded file's SHA-256 (hex, any case).
    static func verify(
        sums: Data?,
        signature: Data?,
        assetName: String,
        actualHex: String,
        publicKey: Curve25519.Signing.PublicKey = ReleaseSignature.publicKey,
        required: Bool = requireUpdateSignature
    ) -> Outcome {
        guard let signature else {
            return required ? .refused("the release is not signed (\(signatureAssetName) missing)") : .unsigned
        }
        guard let sums else {
            return .refused("\(signatureAssetName) is present but \(sumsAssetName) is missing")
        }
        guard let signatureText = String(data: signature, encoding: .utf8) else {
            return .refused("\(signatureAssetName) is not text")
        }
        let trimmed = signatureText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let signatureBytes = Data(base64Encoded: trimmed), signatureBytes.count == 64 else {
            return .refused("\(signatureAssetName) is not a base64 ed25519 signature")
        }
        guard publicKey.isValidSignature(signatureBytes, for: sums) else {
            return .refused("the release signature does not verify")
        }
        guard let expected = expectedHex(sums: sums, assetName: assetName) else {
            return .refused("\(sumsAssetName) has no single line for \(assetName)")
        }
        guard expected == actualHex.lowercased() else {
            return .refused("\(assetName) does not match its signed \(sumsAssetName) line")
        }
        return .verified
    }

    /// The lowercase hex on the `<64 hex>  <name>` line for `assetName`, or
    /// nil when there is none or the matching lines disagree. A `*` binary
    /// marker before the name is accepted (sha256sum -b).
    static func expectedHex(sums: Data, assetName: String) -> String? {
        guard let text = String(data: sums, encoding: .utf8) else { return nil }
        var found: String?
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            guard line.utf8.count > 66 else { continue }
            let hex = String(line.prefix(64))
            let rest = line.dropFirst(64)
            guard hex.utf8.count == 64, hex.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { continue }
            guard rest.hasPrefix("  ") || rest.hasPrefix(" *") else { continue }
            guard rest.dropFirst(2) == assetName else { continue }
            let lower = hex.lowercased()
            if let found, found != lower { return nil }
            found = lower
        }
        return found
    }
}
