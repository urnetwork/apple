//
//  PhysicalPageBenchmarkResultTests.swift
//  networkTests
//

import Foundation
import Testing
@testable import URnetwork

#if os(iOS)
import URnetworkSdk
#endif

struct PhysicalPageBenchmarkResultTests {

    @Test func deviceLogChunksAreBoundedAndRoundTripUnicode() throws {
        let json = "{\"label\":\"\(String(repeating: "低速", count: 500))\"}"
        let recordId = "record-1"
        let lines = PhysicalPageBenchmarkResult.logLines(
            json: json,
            recordId: recordId
        )

        #expect(lines.count > 1)
        var chunks: [String] = []
        for (offset, line) in lines.enumerated() {
            #expect(line.utf8.count < 900)
            let fields = line.split(
                separator: " ",
                maxSplits: 3,
                omittingEmptySubsequences: true
            )
            #expect(fields.count == 4)
            #expect(fields[0] == "[PhysicalPageBenchmarkChunk]")
            #expect(fields[1] == Substring(recordId))
            #expect(fields[2] == "\(offset + 1)/\(lines.count)")
            chunks.append(String(fields[3]))
        }
        let encoded = chunks.joined()
        let data = try #require(Data(base64Encoded: encoded))
        #expect(String(data: data, encoding: .utf8) == json)
    }

    @Test func preCommitFailureSerializesWithNullCommitTime() throws {
        let metrics = PhysicalPageBenchmarkResult.errorMetrics(
            label: "cold-page",
            requestedUrl: "https://example.com/",
            error: "timeout",
            driverCommitMilliseconds: nil,
            driverFinishMilliseconds: 75_000
        )

        let json = try #require(PhysicalPageBenchmarkResult.jsonString(metrics))
        let data = try #require(json.data(using: .utf8))
        let decoded = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        #expect(decoded["driverCommitMs"] is NSNull)
        #expect(decoded["error"] as? String == "timeout")
    }

    @Test func postCommitFailurePreservesCommitTime() throws {
        let metrics = PhysicalPageBenchmarkResult.errorMetrics(
            label: "cold-page",
            requestedUrl: "https://example.com/",
            error: "navigation failed",
            driverCommitMilliseconds: 123.5,
            driverFinishMilliseconds: 456.75
        )

        let json = try #require(PhysicalPageBenchmarkResult.jsonString(metrics))
        let data = try #require(json.data(using: .utf8))
        let decoded = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        #expect(decoded["driverCommitMs"] as? Double == 123.5)
        #expect(decoded["driverFinishMs"] as? Double == 456.75)
    }
}

struct PhysicalPeerTestReadinessTests {

    @Test func directRestoreOnlyAppliesToAnActiveOrStartingConnection() {
        #expect(!PhysicalPeerTestReadiness.shouldRestoreConnectionAfterDirect(
            connectionStatus: nil,
            tunnelConnected: false
        ))
        #expect(!PhysicalPeerTestReadiness.shouldRestoreConnectionAfterDirect(
            connectionStatus: "DISCONNECTED",
            tunnelConnected: false
        ))
        #expect(PhysicalPeerTestReadiness.shouldRestoreConnectionAfterDirect(
            connectionStatus: "DESTINATION_SET",
            tunnelConnected: false
        ))
        #expect(PhysicalPeerTestReadiness.shouldRestoreConnectionAfterDirect(
            connectionStatus: "DISCONNECTED",
            tunnelConnected: true
        ))
    }

    @Test func connectedStatusWithoutTunnelIsNotBenchmarkReady() {
        #expect(!PhysicalPeerTestReadiness.benchmarkIsReady(
            connectionStatus: "CONNECTED",
            tunnelConnected: false,
            selectedPeerId: "provider",
            expectedPeerId: "provider"
        ))
    }

    @Test func tunnelWithoutConnectedStatusIsNotBenchmarkReady() {
        #expect(!PhysicalPeerTestReadiness.benchmarkIsReady(
            connectionStatus: "CONNECTING",
            tunnelConnected: true,
            selectedPeerId: "provider",
            expectedPeerId: "provider"
        ))
    }

    @Test func wrongSelectedPeerIsNotBenchmarkReady() {
        #expect(!PhysicalPeerTestReadiness.benchmarkIsReady(
            connectionStatus: "CONNECTED",
            tunnelConnected: true,
            selectedPeerId: "other-provider",
            expectedPeerId: "provider"
        ))
    }

    @Test func connectedTunnelWithExpectedPeerIsBenchmarkReady() {
        #expect(PhysicalPeerTestReadiness.benchmarkIsReady(
            connectionStatus: "CONNECTED",
            tunnelConnected: true,
            selectedPeerId: "provider",
            expectedPeerId: "provider"
        ))
    }

    @Test func connectedTunnelWithoutExpectedPeerIsBenchmarkReady() {
        #expect(PhysicalPeerTestReadiness.benchmarkIsReady(
            connectionStatus: "CONNECTED",
            tunnelConnected: true,
            selectedPeerId: nil,
            expectedPeerId: nil
        ))
    }

    @Test func directRequiresDisconnectedSdkAndStoppedTunnel() {
        #expect(PhysicalPeerTestReadiness.benchmarkIsReady(
            connectionStatus: "DISCONNECTED",
            tunnelConnected: false,
            selectedPeerId: "stale-provider",
            expectedPeerId: nil,
            route: .direct
        ))
        #expect(!PhysicalPeerTestReadiness.benchmarkIsReady(
            connectionStatus: "DISCONNECTED",
            tunnelConnected: true,
            selectedPeerId: nil,
            expectedPeerId: nil,
            route: .direct
        ))
        #expect(!PhysicalPeerTestReadiness.benchmarkIsReady(
            connectionStatus: "CONNECTED",
            tunnelConnected: false,
            selectedPeerId: nil,
            expectedPeerId: nil,
            route: .direct
        ))
    }

    @Test func vpnRequiresPinnedTransportModeToBeVisible() {
        #expect(!PhysicalPeerTestReadiness.benchmarkIsReady(
            connectionStatus: "CONNECTED",
            tunnelConnected: true,
            selectedPeerId: "provider",
            expectedPeerId: "provider",
            route: .vpn,
            transportMode: "h1",
            expectedTransportMode: "h3"
        ))
        #expect(PhysicalPeerTestReadiness.benchmarkIsReady(
            connectionStatus: "CONNECTED",
            tunnelConnected: true,
            selectedPeerId: "provider",
            expectedPeerId: "provider",
            route: .vpn,
            transportMode: "h3",
            expectedTransportMode: "h3"
        ))
    }
}

struct PhysicalBenchmarkConfigurationTests {

    @Test func omittedValuesPreserveCurrentVpnPolicy() {
        #expect(PhysicalBenchmarkConfiguration.resolve(
            routeValue: nil,
            transportValue: nil,
            expectedPeerId: "provider"
        ) == PhysicalBenchmarkConfiguration(route: .vpn, transportMode: nil))
        #expect(PhysicalBenchmarkConfiguration.resolve(
            routeValue: "vpn",
            transportValue: "current",
            expectedPeerId: nil
        ) == PhysicalBenchmarkConfiguration(route: .vpn, transportMode: nil))
    }

    @Test func vpnAcceptsEverySupportedPinnedMode() {
        for mode in ["auto", "h3", "h1", "dns", "dnspump"] {
            #expect(PhysicalBenchmarkConfiguration.resolve(
                routeValue: "vpn",
                transportValue: mode,
                expectedPeerId: "provider"
            ) == PhysicalBenchmarkConfiguration(
                route: .vpn,
                transportMode: mode
            ))
        }
    }

    @Test func directRejectsTunnelOnlyArguments() {
        #expect(PhysicalBenchmarkConfiguration.resolve(
            routeValue: "direct",
            transportValue: nil,
            expectedPeerId: nil
        ) == PhysicalBenchmarkConfiguration(route: .direct, transportMode: nil))
        #expect(PhysicalBenchmarkConfiguration.resolve(
            routeValue: "direct",
            transportValue: "h3",
            expectedPeerId: nil
        ) == nil)
        #expect(PhysicalBenchmarkConfiguration.resolve(
            routeValue: "direct",
            transportValue: nil,
            expectedPeerId: "provider"
        ) == nil)
        #expect(PhysicalBenchmarkConfiguration.resolve(
            routeValue: "bogus",
            transportValue: nil,
            expectedPeerId: nil
        ) == nil)
        #expect(PhysicalBenchmarkConfiguration.resolve(
            routeValue: "vpn",
            transportValue: "p2p",
            expectedPeerId: nil
        ) == nil)
    }
}

struct PhysicalPageBenchmarkSuiteTests {

    @Test func validSuitePreservesOrderAndLabels() throws {
        let requests = try #require(PhysicalPageBenchmarkSuite.requests(
            json: """
            [
              {"url":"https://example.com/one","label":"first"},
              {"url":"http://example.net/two","label":"second"}
            ]
            """
        ))

        #expect(requests == [
            PhysicalPageBenchmarkRequest(
                urlString: "https://example.com/one",
                label: "first"
            ),
            PhysicalPageBenchmarkRequest(
                urlString: "http://example.net/two",
                label: "second"
            ),
        ])
    }

    @Test func emptySuiteIsRejected() {
        #expect(PhysicalPageBenchmarkSuite.requests(json: "[]") == nil)
    }

    @Test func malformedSuiteIsRejected() {
        #expect(PhysicalPageBenchmarkSuite.requests(json: "{") == nil)
    }

    @Test func nonHttpSuiteUrlIsRejected() {
        #expect(PhysicalPageBenchmarkSuite.requests(
            json: #"[{"url":"file:///tmp/page","label":"local"}]"#
        ) == nil)
    }

    @Test func emptySuiteLabelIsRejected() {
        #expect(PhysicalPageBenchmarkSuite.requests(
            json: #"[{"url":"https://example.com/","label":""}]"#
        ) == nil)
    }
}

#if os(iOS)

struct PhysicalPacketStatsSnapshotTests {

    @Test func sdkSnapshotReadsPerTransportCounters() throws {
        let stats = SdkPacketStats()
        stats.remoteEgressPacketCount = 7
        stats.remoteEgressByteCount = 700
        let h3Stats = SdkPacketStats()
        h3Stats.remoteEgressPacketCount = 5
        h3Stats.remoteEgressByteCount = 500
        let h3 = SdkTransportPacketStats()
        h3.transportType = "h3"
        h3.stats = h3Stats
        let transports = try #require(SdkNewTransportPacketStatsList())
        transports.add(h3)
        stats.transportStats = transports

        let snapshot = PhysicalPacketStatsSnapshot(stats)

        #expect(snapshot.totals.remoteEgressPacketCount == 7)
        #expect(snapshot.totals.remoteEgressByteCount == 700)
        #expect(snapshot.transports["h3"]?.remoteEgressPacketCount == 5)
        #expect(snapshot.transports["h3"]?.remoteEgressByteCount == 500)
        #expect(JSONSerialization.isValidJSONObject(snapshot.jsonObject))
    }

    @Test func deltaPreservesAggregateAndTransportAttribution() {
        var beforeTotals = PhysicalPacketCounterTotals()
        beforeTotals.remoteEgressPacketCount = 10
        beforeTotals.remoteEgressByteCount = 1_000
        var beforeH3 = PhysicalPacketCounterTotals()
        beforeH3.remoteEgressPacketCount = 8
        beforeH3.remoteEgressByteCount = 800

        var afterTotals = beforeTotals
        afterTotals.remoteEgressPacketCount = 15
        afterTotals.remoteEgressByteCount = 1_700
        var afterH3 = beforeH3
        afterH3.remoteEgressPacketCount = 11
        afterH3.remoteEgressByteCount = 1_200
        var afterH1 = PhysicalPacketCounterTotals()
        afterH1.remoteEgressPacketCount = 2
        afterH1.remoteEgressByteCount = 300

        let before = PhysicalPacketStatsSnapshot(
            totals: beforeTotals,
            transports: ["h3": beforeH3]
        )
        let after = PhysicalPacketStatsSnapshot(
            totals: afterTotals,
            transports: ["h3": afterH3, "h1": afterH1]
        )
        let delta = after.subtracting(before)

        #expect(!delta.resetDetected)
        #expect(delta.totals.remoteEgressPacketCount == 5)
        #expect(delta.totals.remoteEgressByteCount == 700)
        #expect(delta.transports["h3"]?.remoteEgressPacketCount == 3)
        #expect(delta.transports["h3"]?.remoteEgressByteCount == 400)
        #expect(delta.transports["h1"]?.remoteEgressPacketCount == 2)
        #expect(delta.transports["h1"]?.remoteEgressByteCount == 300)
    }

    @Test func counterResetIsExplicitRatherThanNegative() {
        var beforeTotals = PhysicalPacketCounterTotals()
        beforeTotals.remoteIngressByteCount = 1_000
        var afterTotals = PhysicalPacketCounterTotals()
        afterTotals.remoteIngressByteCount = 25

        let delta = PhysicalPacketStatsSnapshot(
            totals: afterTotals,
            transports: [:]
        ).subtracting(PhysicalPacketStatsSnapshot(
            totals: beforeTotals,
            transports: [:]
        ))

        #expect(delta.resetDetected)
        #expect(delta.totals.remoteIngressByteCount == 0)
    }
}

#endif
