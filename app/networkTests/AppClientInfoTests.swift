//
//  AppClientInfoTests.swift
//  networkTests
//

import Foundation
import Testing
import URnetworkSdk
@testable import URnetwork

/**
 * Client info (REVOKE-UI-FINAL.md §1.13, §2): every api the app creates or
 * replaces reports the app's device type and version, which the server keeps
 * with each session's last use and Account > Sessions shows. Without it every
 * use from this app reads as an unknown device. The manager runs in the
 * hardware lane (no keychain, no VPN profiles) over real SDK network spaces
 * with loopback endpoints only.
 */
@MainActor
struct AppClientInfoTests {

    @Test func theVersionIsTheReleaseName() {
        #expect(AppClientInfo.appVersion(shortVersion: "2026.10.8", buildVersion: "1066894190") == "2026.10.8-1066894190")
        #expect(AppClientInfo.appVersion(shortVersion: " 2026.10.8 ", buildVersion: "1066894190\n") == "2026.10.8-1066894190")
        #expect(AppClientInfo.appVersion(shortVersion: "2026.10.8", buildVersion: nil) == "2026.10.8")
        #expect(AppClientInfo.appVersion(shortVersion: "2026.10.8", buildVersion: "") == "2026.10.8")
        #expect(AppClientInfo.appVersion(shortVersion: nil, buildVersion: "1066894190") == "")
        #expect(AppClientInfo.appVersion(shortVersion: "", buildVersion: "") == "")
    }

    @Test func theDeviceTypeIsThePlatforms() {
        #if os(macOS)
        #expect(AppClientInfo.deviceType == "macos")
        #else
        #expect(AppClientInfo.deviceType == "ios")
        #endif
    }

    /// The distribution is what tells the server the App Store Mac from the
    /// direct-download Mac, which send the same device type and version.
    @Test func theDistributionIsTheBuilds() {
        #expect(AppClientInfo.distribution(.appStore) == "app_store")
        #expect(AppClientInfo.distribution(.direct) == "mac_direct")
        #expect(AppClientInfo.buildDistribution == AppClientInfo.distribution(BillingDistribution.current))
        #if !DIRECT_DOWNLOAD
        #expect(AppClientInfo.buildDistribution == "app_store")
        #endif
    }

    @Test func everyNetworkSpaceTheManagerActivatesReportsThisApp() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "client-info-test-" + UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let spaceManager = try #require(SdkNewNetworkSpaceManager(directory.path))
        defer {
            spaceManager.close()
            try? FileManager.default.removeItem(at: directory)
        }
        let values = SdkNetworkSpaceValues()
        values.apiUrl = "http://127.0.0.1:1"
        values.platformUrl = "ws://127.0.0.1:1"
        let firstKey = try #require(SdkNewNetworkSpaceKey("client-info-a.example", "test"))
        let secondKey = try #require(SdkNewNetworkSpaceKey("client-info-b.example", "test"))
        let first = try #require(spaceManager.updateNetworkSpaceValues(firstKey, values: values))
        let second = try #require(spaceManager.updateNetworkSpaceValues(secondKey, values: values))

        // a space's own api knows nothing about this app
        #expect(first.getApi()?.getClientInfo()?.deviceType == "unknown")

        let manager = DeviceManager(startupMode: .hardwareNoVPN, automaticallyInitialize: false)
        manager.setActiveNetworkSpace(first)
        let info = try #require(first.getApi()?.getClientInfo())
        #expect(info.version == 1)
        #expect(info.deviceType == AppClientInfo.deviceType)
        #expect(info.appVersion == AppClientInfo.bundleAppVersion)
        #expect(!info.appVersion.isEmpty)
        #expect(info.distribution == AppClientInfo.buildDistribution)

        // a replaced space (another network server) gets it too
        manager.setActiveNetworkSpace(second)
        #expect(second.getApi()?.getClientInfo()?.deviceType == AppClientInfo.deviceType)
        #expect(second.getApi()?.getClientInfo()?.appVersion == AppClientInfo.bundleAppVersion)
        #expect(second.getApi()?.getClientInfo()?.distribution == AppClientInfo.buildDistribution)
        #expect(manager.api?.getClientInfo()?.deviceType == AppClientInfo.deviceType)
    }
}
