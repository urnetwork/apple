//
//  ReleaseSignatureTests.swift
//  networkTests
//
//  The updater's release-signature check (ReleaseSignature): an ed25519
//  signature over SHA256SUMS, then the downloaded file's line. Signed here
//  with a key generated per test, injected in place of the release key.
//

import XCTest
import Foundation
import CryptoKit
@testable import URnetwork

final class ReleaseSignatureTests: XCTestCase {

    let assetName = "URnetwork-2026.11.25-macos.zip"
    let fileHex = String(repeating: "ab", count: 32)
    let otherHex = String(repeating: "cd", count: 32)

    func sums(_ hex: String? = nil) -> Data {
        Data("\(otherHex)  URnetwork-2026.11.25-windows.zip\n\(hex ?? fileHex)  \(assetName)\n".utf8)
    }

    func sign(_ data: Data, _ key: Curve25519.Signing.PrivateKey) throws -> Data {
        Data((try key.signature(for: data).base64EncodedString() + "\n").utf8)
    }

    func testValidSignatureAndMatchingLineVerifies() throws {
        let key = Curve25519.Signing.PrivateKey()
        let body = sums()
        let outcome = ReleaseSignature.verify(
            sums: body, signature: try sign(body, key), assetName: assetName,
            actualHex: fileHex.uppercased(), publicKey: key.publicKey, required: true)
        XCTAssertEqual(outcome, .verified)
    }

    func testSignatureByAnotherKeyIsRefused() throws {
        let body = sums()
        let outcome = ReleaseSignature.verify(
            sums: body, signature: try sign(body, Curve25519.Signing.PrivateKey()), assetName: assetName,
            actualHex: fileHex, publicKey: Curve25519.Signing.PrivateKey().publicKey)
        XCTAssertFalse(outcome.allowsInstall)
    }

    func testTamperedSumsAreRefused() throws {
        let key = Curve25519.Signing.PrivateKey()
        let signature = try sign(sums(), key)
        // the attacker swaps in the hash of their own file
        let outcome = ReleaseSignature.verify(
            sums: sums(otherHex), signature: signature, assetName: assetName,
            actualHex: otherHex, publicKey: key.publicKey)
        XCTAssertFalse(outcome.allowsInstall)
    }

    func testValidSignatureButMismatchedFileIsRefused() throws {
        let key = Curve25519.Signing.PrivateKey()
        let body = sums()
        let outcome = ReleaseSignature.verify(
            sums: body, signature: try sign(body, key), assetName: assetName,
            actualHex: otherHex, publicKey: key.publicKey)
        XCTAssertFalse(outcome.allowsInstall)
    }

    func testValidSignatureWithoutALineForTheFileIsRefused() throws {
        let key = Curve25519.Signing.PrivateKey()
        let body = sums()
        let outcome = ReleaseSignature.verify(
            sums: body, signature: try sign(body, key), assetName: "URnetwork-other-macos.zip",
            actualHex: fileHex, publicKey: key.publicKey)
        XCTAssertFalse(outcome.allowsInstall)
    }

    func testMalformedSignatureIsRefused() {
        let key = Curve25519.Signing.PrivateKey()
        for bad in ["", "not base64!!", Data(count: 10).base64EncodedString()] {
            let outcome = ReleaseSignature.verify(
                sums: sums(), signature: Data(bad.utf8), assetName: assetName,
                actualHex: fileHex, publicKey: key.publicKey)
            XCTAssertFalse(outcome.allowsInstall, bad)
        }
    }

    func testSignatureWithoutSumsIsRefused() throws {
        let key = Curve25519.Signing.PrivateKey()
        let outcome = ReleaseSignature.verify(
            sums: nil, signature: try sign(sums(), key), assetName: assetName,
            actualHex: fileHex, publicKey: key.publicKey)
        XCTAssertFalse(outcome.allowsInstall)
    }

    func testMissingSignatureContinuesUnlessRequired() {
        let key = Curve25519.Signing.PrivateKey()
        XCTAssertEqual(ReleaseSignature.verify(
            sums: sums(), signature: nil, assetName: assetName, actualHex: fileHex,
            publicKey: key.publicKey, required: false), .unsigned)
        XCTAssertFalse(ReleaseSignature.verify(
            sums: sums(), signature: nil, assetName: assetName, actualHex: fileHex,
            publicKey: key.publicKey, required: true).allowsInstall)
    }

    func testStagedDefaultsAndEmbeddedKey() {
        XCTAssertFalse(ReleaseSignature.requireUpdateSignature)
        XCTAssertEqual(ReleaseSignature.publicKey.rawRepresentation.base64EncodedString(),
                       "Qm4V/UTZcuIRMFJuAzDhxf2CK6ycwxF0HFOcFhXBIYQ=")
    }

    func testConflictingLinesForTheFileYieldNoHash() {
        let body = Data("\(fileHex)  \(assetName)\n\(otherHex)  \(assetName)\n".utf8)
        XCTAssertNil(ReleaseSignature.expectedHex(sums: body, assetName: assetName))
        XCTAssertEqual(ReleaseSignature.expectedHex(sums: Data("\(fileHex) *\(assetName)\r\n".utf8), assetName: assetName), fileHex)
    }
}
