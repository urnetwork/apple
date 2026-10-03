//
//  ProvideControlModeOwnershipTests.swift
//  networkTests
//
//  The provide control mode is the user's choice. Only the surfaces where the
//  user picks it, and the device manager that loads and persists it, may write
//  it. A plan change (free -> Pro) must never change it: the app used to reset
//  it to Never at the upgrade, so paying users silently stopped providing.
//

import Foundation
import Testing

struct ProvideControlModeOwnershipTests {

    /// Files allowed to write the provide control mode, relative to `app/network`.
    private static let writerPaths: Set<String> = [
        // loads the persisted mode from the device, and clears it with no device
        "Shared/ViewModels/DeviceManager.swift",
        // the user's choice in onboarding and settings
        "Shared/Views/Introduction/ProvideControlModeList.swift",
        // the physical peer test driver's explicit setup
        "Shared/PhysicalPeerTestDriver.swift",
    ]

    /// Files on the plan and purchase paths, which must not touch the mode at all.
    private static let planPaths: [String] = [
        "Main/MainView.swift",
        "Shared/ViewModels/SubscriptionBalanceViewModel.swift",
    ]

    // …/apple/app/networkTests/ProvideControlModeOwnershipTests.swift -> …/apple/app/network
    private static let networkRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("network")

    private static let writePattern = try! NSRegularExpression(
        pattern: #"provideControlMode\s*=(?!=)|setProvideControlMode\("#
    )

    private static func swiftSources() throws -> [(path: String, text: String)] {
        let root = networkRoot.standardizedFileURL.path
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

    private static func writes(_ text: String) -> Int {
        writePattern.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    @Test func onlyTheUserChoiceAndTheDeviceManagerWriteTheMode() throws {
        let sources = try Self.swiftSources()
        try #require(!sources.isEmpty, "app sources not found under \(Self.networkRoot.path)")
        let writers = Set(sources.filter { Self.writes($0.text) > 0 }.map { $0.path })
        #expect(writers.isSubset(of: Self.writerPaths), "unexpected writers: \(writers.subtracting(Self.writerPaths).sorted())")
    }

    @Test func thePlanPathsNeverReferenceTheMode() throws {
        for path in Self.planPaths {
            let text = try String(contentsOf: Self.networkRoot.appendingPathComponent(path), encoding: .utf8)
            #expect(!text.contains("provideControlMode"), "\(path) must not change the provide control mode on a plan change")
            #expect(!text.contains("didDetectUpgradeToPro"), "\(path) must not signal a provide reset on upgrade")
        }
    }
}
