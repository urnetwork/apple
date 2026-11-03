//
//  PurchaseFlowWiringTests.swift
//  networkTests
//
//  A surface that sells Pro buys through the store makeSubscriptionStore makes
//  and leaves the connection to it (ConnectionAwareSubscriptionStore), so a new
//  surface gets the macOS disconnect notice by buying at all. Each surface used
//  to carry its own copy of the disconnect and the restore. The factory's
//  `connection` parameter holds that at compile time for the store it makes;
//  this holds the rest: no copy comes back, and nothing buys from a store
//  directly.
//
//  Reads the Swift sources under network/; no device.
//

import Foundation
import Testing

struct PurchaseFlowWiringTests {

    // …/apple/app/networkTests/PurchaseFlowWiringTests.swift -> …/apple/app/network
    private static let networkRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("network")

    /// The surfaces that sell, relative to `network`.
    private static let surfaces = [
        "Main/Account/AccountRootView.swift",
        "Main/Connect/ConnectView-macOS.swift",
        "Shared/Views/Introduction/IntroductionView.swift",
        "Shared/Views/Introduction/OnboardingOfferSheet.swift",
    ]

    /// The sources, with their comments gone: they may name what the code may not.
    private static func swiftSources() throws -> [(path: String, code: String)] {
        let root = networkRoot.standardizedFileURL.path
        guard let enumerator = FileManager.default.enumerator(atPath: root) else {
            return []
        }
        var sources: [(path: String, code: String)] = []
        while let relativePath = enumerator.nextObject() as? String {
            guard relativePath.hasSuffix(".swift") else { continue }
            let text = try String(contentsOfFile: root + "/" + relativePath, encoding: .utf8)
            sources.append((relativePath, code(text)))
        }
        return sources
    }

    private static func code(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.hasPrefix("//") && !trimmed.hasPrefix("*") && !trimmed.hasPrefix("/*")
            }
            .map { line in
                line.range(of: " // ").map { String(line[..<$0.lowerBound]) } ?? String(line)
            }
            .joined(separator: "\n")
    }

    @Test func theScanSeesTheCodeAndNotTheComments() {
        let code = Self.code("""
            // restoreConnect(
            /**
             * restoreConnect(
             */
            let a = 1 // restoreConnect(
            model.disconnect()
            """)
        #expect(!code.contains("restoreConnect("))
        #expect(code.contains("let a = 1"))
        #expect(code.contains("model.disconnect()"))
    }

    /// The restore has one caller, the flow in the view model. Every copy of the
    /// disconnect came with one.
    @Test func onlyThePurchaseFlowRestoresAConnection() throws {
        let sources = try Self.swiftSources()
        try #require(!sources.isEmpty, "app sources not found under \(Self.networkRoot.path)")
        let callers = sources
            .filter { $0.code.contains("restoreConnect(") }
            .map { $0.path }
        #expect(
            callers == ["Shared/ViewModels/ConnectViewModel.swift"],
            "the disconnect and restore around a purchase belong to the purchase flow: \(callers.sorted())"
        )
    }

    /// `getConnected()` is the rpc link to the extension, up whenever the
    /// extension runs. It says nothing about a connection the user requested,
    /// which is what a purchase drops.
    @Test func noSurfaceDecidesOnTheRpcLink() throws {
        let sources = try Self.swiftSources()
        for surface in Self.surfaces {
            let source = try #require(sources.first { $0.path == surface }, "\(surface) not found")
            #expect(!source.code.contains("getConnected()"), "\(surface) reads the rpc link")
        }
    }

    /// What buys from a store directly, past the flow: those stores' own files
    /// and the factory aside, only the iOS connect view, which never drops the
    /// connection (the A6 note on AppStoreSubscriptionManager.purchase).
    @Test func nothingBuysPastTheFlow() throws {
        let allowed: [String: Set<String>] = [
            "subscriptionManager.purchase(": ["Main/Connect/ConnectView-iOS.swift"],
            "subscriptionManager.redeemOffer(": [],
            "stripeSubscriptionStore.purchase(": [],
            "stripeSubscriptionStore.redeemOffer(": [],
            "StoreKitSubscriptionStore(": ["Shared/Billing/SubscriptionStore.swift"],
            "ConnectionAwareSubscriptionStore(": ["Shared/Billing/SubscriptionStore.swift"],
        ]
        let sources = try Self.swiftSources()
        try #require(!sources.isEmpty, "app sources not found under \(Self.networkRoot.path)")
        for (call, paths) in allowed {
            let callers = Set(sources.filter { $0.code.contains(call) }.map { $0.path })
            #expect(callers.isSubset(of: paths), "\(call) from \(callers.subtracting(paths).sorted())")
        }
    }
}
