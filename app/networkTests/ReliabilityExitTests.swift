//
//  ReliabilityExitTests.swift
//  networkTests
//
//  The developer screen's exit readout. Its state line takes every word from
//  the string catalog (the dev_state_* keys the Windows and Linux pages use)
//  or from the sdk (a window type, a warning cause), never from an English
//  literal: it used to append "tier", "benched", "done" and "proven" in every
//  language. Its policy line shows the security rules generation of each
//  exit's provider: the number once the provider's diagnostics arrive,
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

    /// One exit with its state fields set, through the store's own mapping.
    private func exit(
        windowType: String = "quality",
        tier: Int32 = 1,
        effectiveTier: Int32 = 1,
        quarantined: Bool = false,
        warning: Bool = false,
        warningCause: String = "",
        done: Bool = false,
        p2pOnly: Bool = false,
        proven: Bool = false
    ) throws -> ReliabilityExit {
        var parseError: NSError?
        let sdkExit = SdkExit()
        sdkExit.clientId = try #require(SdkParseId(Self.clientIdString, &parseError))
        sdkExit.windowType = windowType
        sdkExit.tier = tier
        sdkExit.effectiveTier = effectiveTier
        sdkExit.quarantined = quarantined
        sdkExit.warning = warning
        sdkExit.warningCause = warningCause
        sdkExit.done = done
        sdkExit.p2pOnly = p2pOnly
        sdkExit.proven = proven
        return try #require(ReliabilityExit(sdkExit))
    }

    /// The test host runs in English, so the catalog words read as the
    /// store's English.
    @Test func theStateLineIsMadeOfTheCatalogWords() throws {
        let benched = try exit(
            tier: 1, effectiveTier: 3, quarantined: true, warning: true, warningCause: "unhealthy",
            done: true, p2pOnly: true, proven: true
        )
        #expect(benched.stateLine == "quality · tier 1→3 · benched · done · p2p · proven")
        // an exit without a window type reads as the sdk's auto window type
        #expect(try exit(windowType: "").stateLine == "\(SdkWindowTypeAuto) · tier 1")
        // the sdk's warning cause shows verbatim; without one, "warned"
        #expect(try exit(warning: true, warningCause: "starved").stateLine == "quality · tier 1 · starved")
        #expect(try exit(warning: true).stateLine == "quality · tier 1 · warned")
    }

    /// Every state word is in the catalog with its translations; p2p is a
    /// transport name, never translated.
    @Test func theStateWordsAreInTheCatalog() throws {
        let data = try Data(contentsOf: Self.appRoot.appendingPathComponent("network/Shared/Resources/Localizable.xcstrings"))
        let catalog = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let strings = try #require(catalog?["strings"] as? [String: Any])
        for (key, german) in [
            ("tier %@", "Stufe %@"),
            ("benched", "auf der Ersatzbank"),
            ("warned", "gewarnt"),
            ("done", "fertig"),
            ("proven", "bewährt"),
        ] {
            let entry = try #require(strings[key] as? [String: Any], "\(key) is not in the catalog")
            let localizations = try #require(entry["localizations"] as? [String: Any])
            let de = (localizations["de"] as? [String: Any])?["stringUnit"] as? [String: Any]
            #expect(de?["value"] as? String == german, "\(key) de")
        }
        let p2p = try #require(strings["p2p"] as? [String: Any], "p2p is not in the catalog")
        #expect(p2p["shouldTranslate"] as? Bool == false)
    }

    /// No exit readout word is a hardcoded literal. In ReliabilityExit every
    /// literal with a letter in it is the argument of String(localized:); in
    /// the view's exit row it is the first argument of Text( or Button(, which
    /// look it up in the catalog (CatalogLookupTests checks those keys).
    @Test func noExitReadoutWordIsAHardcodedLiteral() throws {
        let store = try String(contentsOf: Self.appRoot.appendingPathComponent("network/Shared/ViewModels/ReliabilityStore.swift"), encoding: .utf8)
        let view = try String(contentsOf: Self.appRoot.appendingPathComponent("network/Main/Account/Settings/Developer/DeveloperView.swift"), encoding: .utf8)
        let exitModel = try #require(Self.body(of: "struct ReliabilityExit", in: store))
        let exitRow = try #require(Self.body(of: "private func exitRow(", in: view))
        #expect(Self.unlocalizedWords(in: exitModel, lookups: ["String(localized:"]) == [])
        #expect(Self.unlocalizedWords(in: exitRow, lookups: ["Text(", "Button("]) == [])
    }

    /// The braces-balanced body after the first `{` that follows `declaration`.
    private static func body(of declaration: String, in source: String) -> String? {
        guard let start = source.range(of: declaration),
              let open = source[start.upperBound...].firstIndex(of: "{") else {
            return nil
        }
        var depth = 0
        var index = open
        while index < source.endIndex {
            if source[index] == "{" {
                depth += 1
            } else if source[index] == "}" {
                depth -= 1
                if depth == 0 {
                    return String(source[open...index])
                }
            }
            index = source.index(after: index)
        }
        return nil
    }

    /// The literals in `code` (comments removed) that hold a letter outside
    /// their interpolations and are not the argument of one of `lookups`.
    private static func unlocalizedWords(in code: String, lookups: [String]) -> [String] {
        let withoutComments = code
            .replacingOccurrences(of: #"/\*[\s\S]*?\*/"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"//[^\n]*"#, with: "", options: .regularExpression)
        let literal = try! NSRegularExpression(pattern: #""(?:[^"\\\n]|\\.)*""#)
        let text = withoutComments as NSString
        var words: [String] = []
        for match in literal.matches(in: withoutComments, range: NSRange(location: 0, length: text.length)) {
            let value = text.substring(with: match.range)
            let outsideInterpolations = value.replacingOccurrences(of: #"\\\([^)]*\)"#, with: "", options: .regularExpression)
            guard outsideInterpolations.contains(where: { $0.isLetter }) else {
                continue
            }
            let before = text.substring(to: match.range.location).trimmingCharacters(in: .whitespaces)
            if !lookups.contains(where: { before.hasSuffix($0) }) {
                words.append(value)
            }
        }
        return words
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
