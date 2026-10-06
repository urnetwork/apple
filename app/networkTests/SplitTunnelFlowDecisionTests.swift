//
//  SplitTunnelFlowDecisionTests.swift
//  networkTests
//
//  The macOS split tunnel's transparent proxy relays a flow outside the VPN
//  only when it comes from an excluded app and goes somewhere the tunnel
//  would capture; every other flow is declined and stays where it was going.
//  These pin that decision (network/Shared/SplitTunnel/SplitTunnelFlowDecision.swift),
//  which the system extension compiles as is.
//

import Testing
import Foundation
@testable import URnetwork

struct SplitTunnelFlowDecisionTests {

    // MARK: apps

    @Test func anExcludedAppMatchesItsOwnSigningIdentifierIgnoringCase() {
        let matcher = SplitTunnelAppMatcher(excludedApps: ["com.example.Bank"])
        #expect(matcher.matches(signingIdentifier: "com.example.Bank"))
        #expect(matcher.matches(signingIdentifier: "COM.EXAMPLE.BANK"))
        #expect(!matcher.matches(signingIdentifier: "com.example.Other"))
    }

    @Test func anExcludedAppCoversItsHelperProcesses() {
        // a browser's network service runs in a helper process, signed below
        // the browser's own identifier
        let matcher = SplitTunnelAppMatcher(excludedApps: ["com.example.Browser"])
        #expect(matcher.matches(signingIdentifier: "com.example.Browser.helper"))
        #expect(matcher.matches(signingIdentifier: "com.example.Browser.helper.renderer"))
    }

    @Test func helperMatchingNeedsTheDotBoundary() {
        let matcher = SplitTunnelAppMatcher(excludedApps: ["com.example.Browser"])
        #expect(!matcher.matches(signingIdentifier: "com.example.BrowserBeta"))
        #expect(!matcher.matches(signingIdentifier: "com.example"))
        #expect(!matcher.matches(signingIdentifier: "com.example.browse"))
    }

    @Test func aShortIdentifierNeverTakesAWholeVendorOutOfTheTunnel() {
        // a vendor's two-label prefix must not cover every app and system
        // process the vendor signs
        let matcher = SplitTunnelAppMatcher(excludedApps: ["com.example", "Tool"])
        #expect(matcher.matches(signingIdentifier: "com.example"))
        #expect(!matcher.matches(signingIdentifier: "com.example.Browser"))
        #expect(!matcher.matches(signingIdentifier: "com.example.Engine.Networking"))
        #expect(matcher.matches(signingIdentifier: "Tool"))
        #expect(!matcher.matches(signingIdentifier: "Tool.helper"))
    }

    @Test func aSystemProcessWithNoIdentifierIsNeverExcluded() {
        let matcher = SplitTunnelAppMatcher(excludedApps: ["com.example.Bank"])
        #expect(!matcher.matches(signingIdentifier: ""))
        #expect(SplitTunnelAppMatcher(excludedApps: []).isEmpty)
        #expect(!SplitTunnelAppMatcher(excludedApps: []).matches(signingIdentifier: "com.example.Bank"))
    }

    // MARK: destinations

    @Test func publicAddressesAreTunneled() {
        // documentation addresses (RFC 5737, RFC 3849), and one of them behind
        // the NAT64 prefix (RFC 6052)
        for host in ["192.0.2.1", "198.51.100.7", "203.0.113.46", "2001:db8::1", "2001:db8:85a3::8a2e:370:7334", "64:ff9b::c000:201"] {
            #expect(SplitTunnelDestination.isTunneled(host: host), "\(host)")
        }
    }

    @Test func destinationsTheTunnelLeavesAloneAreNot() {
        for host in [
            // private ranges the tunnel excludes
            "10.1.2.3", "172.16.0.1", "172.31.255.254", "192.168.1.10",
            // loopback, unspecified, link-local
            "127.0.0.1", "0.0.0.0", "169.254.10.20",
            // shared address space (carrier NAT, overlay VPNs on their own utun)
            "100.64.0.1", "100.127.255.254",
            // multicast, reserved, limited broadcast
            "224.0.0.251", "239.255.255.250", "240.0.0.1", "255.255.255.255",
            // IPv6 loopback, unspecified, link-local, unique local, multicast
            "::1", "::", "fe80::1", "fe80::1%en0", "fd12:3456:789a::1", "ff02::fb",
            // an IPv4 private address written as IPv6
            "::ffff:192.168.1.1",
        ] {
            #expect(!SplitTunnelDestination.isTunneled(host: host), "\(host)")
        }
    }

    @Test func theRangeEdgesAreExact() {
        #expect(SplitTunnelDestination.isTunneled(host: "172.15.255.255"))
        #expect(SplitTunnelDestination.isTunneled(host: "172.32.0.0"))
        #expect(SplitTunnelDestination.isTunneled(host: "100.63.255.255"))
        #expect(SplitTunnelDestination.isTunneled(host: "100.128.0.0"))
        #expect(SplitTunnelDestination.isTunneled(host: "169.253.255.255"))
        #expect(SplitTunnelDestination.isTunneled(host: "223.255.255.255"))
        #expect(SplitTunnelDestination.isTunneled(host: "::ffff:203.0.113.1"))
        #expect(SplitTunnelDestination.isTunneled(host: "fec0::1"))
        #expect(SplitTunnelDestination.isTunneled(host: "fe00::1"))
    }

    @Test func localNamesAreNotTunneledOtherNamesAre() {
        #expect(!SplitTunnelDestination.isTunneled(host: "localhost"))
        #expect(!SplitTunnelDestination.isTunneled(host: "printer.local"))
        #expect(!SplitTunnelDestination.isTunneled(host: "printer.local."))
        #expect(!SplitTunnelDestination.isTunneled(host: ""))
        #expect(SplitTunnelDestination.isTunneled(host: "bank.example.com"))
    }

    @Test func theAddressBytesTheExtensionReadsClassifyTheSameWay() {
        // the provider classifies Network.framework's raw address bytes
        #expect(SplitTunnelDestination.isTunneled(ipv4: [203, 0, 113, 1]))
        #expect(!SplitTunnelDestination.isTunneled(ipv4: [192, 168, 0, 1]))
        #expect(!SplitTunnelDestination.isTunneled(ipv4: [1, 2, 3]))
        var loopback = [UInt8](repeating: 0, count: 16)
        loopback[15] = 1
        #expect(!SplitTunnelDestination.isTunneled(ipv6: loopback))
        #expect(SplitTunnelDestination.isTunneled(ipv6: [0x20, 0x01, 0x0d, 0xb8] + [UInt8](repeating: 0, count: 11) + [0x88]))
    }

    // MARK: the verdict

    private let matcher = SplitTunnelAppMatcher(excludedApps: ["com.example.Bank"])

    @Test func anExcludedAppGoingToTheInternetIsRelayed() {
        #expect(SplitTunnelFlowDecision.verdict(
            signingIdentifier: "com.example.Bank",
            destinationTunneled: true,
            isBound: false,
            matcher: matcher
        ) == .relay)
    }

    @Test func everyOtherAppIsDeclinedAndStaysInTheTunnel() {
        #expect(SplitTunnelFlowDecision.verdict(
            signingIdentifier: "com.example.Browser",
            destinationTunneled: true,
            isBound: false,
            matcher: matcher
        ) == .decline)
        #expect(SplitTunnelFlowDecision.verdict(
            signingIdentifier: "",
            destinationTunneled: true,
            isBound: false,
            matcher: matcher
        ) == .decline)
    }

    @Test func anExcludedAppsLocalTrafficKeepsItsOwnRoute() {
        #expect(SplitTunnelFlowDecision.verdict(
            signingIdentifier: "com.example.Bank",
            destinationTunneled: false,
            isBound: false,
            matcher: matcher
        ) == .decline)
        // not an address the proxy can dial
        #expect(SplitTunnelFlowDecision.verdict(
            signingIdentifier: "com.example.Bank",
            destinationTunneled: nil,
            isBound: false,
            matcher: matcher
        ) == .decline)
    }

    @Test func aSocketTheAppBoundToAnInterfaceKeepsIt() {
        #expect(SplitTunnelFlowDecision.verdict(
            signingIdentifier: "com.example.Bank",
            destinationTunneled: true,
            isBound: true,
            matcher: matcher
        ) == .decline)
    }

    // MARK: failures

    @Test func aRelayFailureReachesTheAppAsItsOwnConnectFailure() {
        #expect(SplitTunnelFlowFailure.from(posixErrorCode: ECONNREFUSED) == .refused)
        #expect(SplitTunnelFlowFailure.from(posixErrorCode: ETIMEDOUT) == .timedOut)
        #expect(SplitTunnelFlowFailure.from(posixErrorCode: EHOSTUNREACH) == .hostUnreachable)
        #expect(SplitTunnelFlowFailure.from(posixErrorCode: ENETUNREACH) == .hostUnreachable)
        #expect(SplitTunnelFlowFailure.from(posixErrorCode: ECONNRESET) == .peerReset)
        #expect(SplitTunnelFlowFailure.from(posixErrorCode: EINVAL) == .aborted)
    }
}
