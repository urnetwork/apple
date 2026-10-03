//
//  SupportContactTests.swift
//  networkTests
//
//  Discord is unreachable in some regions, so a support surface that offers
//  only the Discord invite leaves those users with no way to reach support.
//  Every app source that links the Discord invite must also offer the support
//  email.
//

import Foundation
import Testing
@testable import URnetwork

struct SupportContactTests {

    // …/apple/app/networkTests/SupportContactTests.swift -> …/apple/app
    private static let appRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let discordInvite = "discord.com/invite/"
    private static let emailMarkers = ["mailto:support@ur.io", "SupportContact.emailUrl"]

    private static func swiftSources() throws -> [(path: String, text: String)] {
        let root = appRoot.appendingPathComponent("network").standardizedFileURL.path
        guard let enumerator = FileManager.default.enumerator(atPath: root) else {
            return []
        }
        var sources: [(path: String, text: String)] = []
        while let relativePath = enumerator.nextObject() as? String {
            guard relativePath.hasSuffix(".swift") else { continue }
            let text = try String(contentsOfFile: root + "/" + relativePath, encoding: .utf8)
            sources.append((relativePath, text))
        }
        return sources
    }

    @Test func theEmailIsAMailtoLinkToSupport() {
        #expect(SupportContact.email == "support@ur.io")
        #expect(SupportContact.emailUrl.scheme == "mailto")
        #expect(SupportContact.emailUrl.absoluteString == "mailto:support@ur.io")
        #expect(SupportContact.discordUrl.absoluteString.contains(Self.discordInvite))
    }

    @Test func everyDiscordSupportSurfaceAlsoOffersEmail() throws {
        let sources = try Self.swiftSources()
        try #require(!sources.isEmpty, "app sources not found under \(Self.appRoot.path)")
        let discordSurfaces = sources.filter {
            $0.text.contains(Self.discordInvite) || $0.text.contains("SupportContact.discordUrl")
        }
        // the feedback screen, the iOS and macOS settings, and the plan error screen
        #expect(discordSurfaces.count >= 4)
        for source in discordSurfaces where source.path != "Shared/Models/SupportContact.swift" {
            #expect(
                Self.emailMarkers.contains { source.text.contains($0) },
                "\(source.path) offers Discord without the support email"
            )
        }
    }

    @Test func theEmailLineIsLocalized() throws {
        let catalogUrl = Self.appRoot.appendingPathComponent("network/Shared/Resources/Localizable.xcstrings")
        let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf: catalogUrl)) as? [String: Any]
        let strings = try #require(catalog?["strings"] as? [String: Any])
        let entry = try #require(strings["Contact support at [support@ur.io](mailto:support@ur.io)"] as? [String: Any])
        let localizations = try #require(entry["localizations"] as? [String: Any])
        for locale in ["ar", "de", "es", "ru", "zh-Hans", "ja", "fr"] {
            let unit = (localizations[locale] as? [String: Any])?["stringUnit"] as? [String: Any]
            let value = unit?["value"] as? String
            #expect(value?.contains("[support@ur.io](mailto:support@ur.io)") == true, "\(locale) must keep the email link")
        }
    }
}
