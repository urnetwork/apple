//
//  PhysicalPageBenchmarkResultTests.swift
//  networkTests
//

import Foundation
import Testing
@testable import URnetwork

struct PhysicalPageBenchmarkResultTests {

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
