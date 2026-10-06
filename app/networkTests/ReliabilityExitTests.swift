//
//  ReliabilityExitTests.swift
//  networkTests
//
//  The developer screen's exit readout shows the security rules generation of
//  each exit's provider: the number once the provider's diagnostics arrive,
//  "unknown" for a provider that reports its policy without one, and nothing
//  before its first diagnostics. The sdk carried no generation before, so no
//  readout could show which exits run older rules.
//

import Foundation
import Testing
import URnetworkSdk
@testable import URnetwork

struct ReliabilityExitTests {

    // …/apple/app/networkTests/ReliabilityExitTests.swift -> …/apple/app
    private static let appRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let clientIdString = "018f2b6e-3c4d-7a8b-9c0d-1e2f3a4b5c6d"

    /// One exit as the sdk hands it to the store, through the store's own
    /// mapping.
    private func exit(providerDiagnosticsAvailable: Bool, providerSecurityPolicyGeneration: Int64) throws -> ReliabilityExit {
        var parseError: NSError?
        let sdkExit = SdkExit()
        sdkExit.clientId = try #require(SdkParseId(Self.clientIdString, &parseError))
        sdkExit.providerDiagnosticsAvailable = providerDiagnosticsAvailable
        sdkExit.providerSecurityPolicyGeneration = providerSecurityPolicyGeneration
        return try #require(ReliabilityExit(sdkExit))
    }

    @Test func noPolicyLineBeforeTheProvidersFirstDiagnostics() throws {
        for generation: Int64 in [0, 2] {
            let row = try exit(providerDiagnosticsAvailable: false, providerSecurityPolicyGeneration: generation)
            #expect(row.policyGenerationLine == nil, "generation \(generation) without diagnostics")
        }
    }

    @Test func theReportedGenerationIsShown() throws {
        let row = try exit(providerDiagnosticsAvailable: true, providerSecurityPolicyGeneration: 2)
        #expect(row.providerSecurityPolicyGeneration == 2)
        #expect(row.policyGenerationLine == "policy generation 2")
    }

    @Test func aProviderWithoutAGenerationReadsUnknown() throws {
        let row = try exit(providerDiagnosticsAvailable: true, providerSecurityPolicyGeneration: 0)
        #expect(row.policyGenerationLine == "policy generation unknown")
    }

    /// A generation change is a row change: the store republishes its exits
    /// only when they differ.
    @Test func aGenerationChangeChangesTheRow() throws {
        let older = try exit(providerDiagnosticsAvailable: true, providerSecurityPolicyGeneration: 1)
        let newer = try exit(providerDiagnosticsAvailable: true, providerSecurityPolicyGeneration: 2)
        #expect(older != newer)
    }

    /// String(localized:) falls back to its own English when the catalog lacks
    /// a key, so the lines above read the same without one: the catalog must
    /// carry both, translated.
    @Test func thePolicyLinesAreInTheCatalog() throws {
        let data = try Data(contentsOf: Self.appRoot.appendingPathComponent("network/Shared/Resources/Localizable.xcstrings"))
        let catalog = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let strings = try #require(catalog?["strings"] as? [String: Any])
        for (key, german) in [
            ("policy generation %lld", "Richtliniengeneration %lld"),
            ("policy generation unknown", "Richtliniengeneration unbekannt"),
        ] {
            let entry = try #require(strings[key] as? [String: Any], "\(key) is not in the catalog")
            let localizations = try #require(entry["localizations"] as? [String: Any])
            let de = (localizations["de"] as? [String: Any])?["stringUnit"] as? [String: Any]
            #expect(de?["value"] as? String == german, "\(key) de")
        }
    }
}
