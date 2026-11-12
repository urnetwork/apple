//
//  PlanAccountNameTests.swift
//  networkTests
//
//  Customers with several accounts read the plan of one and had paid on
//  another, and no plan surface said which account it showed (support inbox
//  6546; also 7765, 6711, 706 and 7261). The Account screen's plan, the
//  Connect screen's plan card and the purchase confirmation now show
//  "Account: <name>" from the sdk's one rule (SdkPlanAccountName, tested in
//  the sdk), which answers "" for a guest or an empty name: then nothing
//  shows.
//
//  Reads the Swift sources under network/ and the generated string catalog;
//  no device.
//

import Foundation
import Testing

struct PlanAccountNameTests {

    // …/apple/app/networkTests/PlanAccountNameTests.swift -> …/apple/app
    private static let appRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static func source(_ path: String) throws -> String {
        try String(contentsOf: appRoot.appendingPathComponent(path), encoding: .utf8)
    }

    private static let accountLine = #"Text("Account: \("#

    /// The plan cards name the account between the plan and the usage bar,
    /// from the sdk's rule, and only when it names one.
    @Test func thePlanCardsNameTheAccount() throws {
        for path in [
            "network/Main/Account/AccountRootView.swift",
            "network/Main/Connect/ConnectActions/ConnectActions.swift",
        ] {
            let source = try Self.source(path)
            let plan = try #require(source.range(of: #"Text("Plan")"#), "\(path) has no plan card")
            let usage = try #require(source.range(of: "UsageBar(", range: plan.upperBound..<source.endIndex), "\(path) has no usage bar")
            let card = source[plan.upperBound..<usage.lowerBound]
            #expect(card.contains("SdkPlanAccountName("), "\(path)")
            #expect(card.contains("if !planAccountName.isEmpty"), "\(path)")
            #expect(card.contains(Self.accountLine), "\(path)")
        }
    }

    /// The purchase confirmation names the account the purchase is for, in
    /// every phase, from the network name every caller passes.
    @Test func theConfirmationNamesTheAccount() throws {
        let source = try Self.source("network/Shared/Views/PurchaseSuccessView.swift")
        #expect(source.contains("let networkName: String?"))
        #expect(source.contains("SdkPlanAccountName(networkName"))
        #expect(source.contains("if !accountName.isEmpty"))
        #expect(source.contains(Self.accountLine))

        // the sheet hands on what its callers pass: the Account screen its
        // network name, the rest the jwt's
        for path in [
            "network/Shared/Views/UpgradeSubscriptionSheet.swift",
            "network/Main/Account/AccountRootView.swift",
        ] {
            let caller = try Self.source(path)
            #expect(caller.contains("networkName: networkName,"), "\(path)")
        }
        for path in [
            "network/Shared/Views/Introduction/IntroductionView.swift",
            "network/Shared/Views/Introduction/OnboardingOfferSheet.swift",
            "network/Main/Connect/ConnectView-iOS.swift",
            "network/Main/Connect/ConnectView-macOS.swift",
        ] {
            let caller = try Self.source(path)
            #expect(caller.contains("networkName: deviceManager.parsedJwt?.networkName,"), "\(path)")
        }
    }

    /// The line comes from the localizations store, in every locale the
    /// catalog ships (some read "Account" in their own language too).
    @Test func theAccountLineIsInEveryLocale() throws {
        let data = try Data(contentsOf: Self.appRoot.appendingPathComponent("network/Shared/Resources/Localizable.xcstrings"))
        let catalog = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let strings = try #require(catalog?["strings"] as? [String: Any])

        var locales = Set<String>()
        for case let entry as [String: Any] in strings.values {
            if let localizations = entry["localizations"] as? [String: Any] {
                locales.formUnion(localizations.keys)
            }
        }
        #expect(locales.contains("zh-Hans"))

        let entry = try #require(strings["Account: %@"] as? [String: Any], "the catalog has no account line")
        #expect(entry["extractionState"] as? String != "stale")
        let localizations = try #require(entry["localizations"] as? [String: Any])
        var missing: [String] = []
        for locale in locales.sorted() {
            let unit = (localizations[locale] as? [String: Any])?["stringUnit"] as? [String: Any]
            let value = unit?["value"] as? String ?? ""
            if !value.contains("%@") {
                missing.append(locale)
            }
        }
        #expect(missing.isEmpty, "the account line is missing or has no name in \(missing)")
    }
}
