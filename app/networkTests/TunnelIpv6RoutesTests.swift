//
//  TunnelIpv6RoutesTests.swift
//  networkTests
//

import Foundation
import Testing

/**
 * The tunnel's IPv6 exclusions and the settings signature. The route helpers
 * are compiled into this bundle from the extension sources, so what is checked
 * here is what the packet tunnel installs.
 */
struct TunnelIpv6RoutesTests {

    @Test func exclusionsAreLinkLocalUlaMulticastAndLoopback() {
        #expect(tunnelIpv6ExcludedRoutes() == [
            TunnelIpv6Route(address: "fe80::", prefixLength: 10),
            TunnelIpv6Route(address: "fc00::", prefixLength: 7),
            TunnelIpv6Route(address: "ff00::", prefixLength: 8),
            TunnelIpv6Route(address: "::1", prefixLength: 128),
        ])
    }

    @Test func excludedAddressesBypassTheTunnel() {
        for address in [
            "fe80::1",                      // link-local
            "febf:ffff::1",                 // the top of fe80::/10
            "fc00::1",                      // ULA
            "fd12:3456:789a::1",            // a home network's ULA
            "fd00:7572:6e65:1234::abcd",    // the tunnel interface's own ULA /48
            "ff02::1",                      // multicast
            "ff05::1:3",
            "::1",                          // loopback
        ] {
            #expect(tunnelIpv6Excluded(address), "\(address) must bypass the tunnel")
        }
    }

    @Test func routableAddressesGoThroughTheTunnel() {
        for address in [
            "2606:4700:4700::1111",         // a public resolver
            "2001:4860:4860::8888",
            "2a00:1450:4001:80b::200e",     // a web host
            "2001:db8::65:49:70:65",        // the tunnel's own resolver address
            "fec0::1",                      // deprecated site-local, just above fe80::/10
            "::",                           // unspecified
            "::ffff:10.0.0.1",              // v4-mapped: not an IPv6 exclusion (the v4 routes decide)
            "64:ff9b::a00:1",               // NAT64
        ] {
            #expect(!tunnelIpv6Excluded(address), "\(address) must go through the tunnel")
        }
    }

    @Test func routeContainmentHonorsThePrefixLength() {
        let route = TunnelIpv6Route(address: "2001:db8::", prefixLength: 32)
        #expect(tunnelIpv6RouteContains(route, "2001:db8:ffff::1"))
        #expect(!tunnelIpv6RouteContains(route, "2001:db9::1"))
        #expect(tunnelIpv6RouteContains(TunnelIpv6Route(address: "::", prefixLength: 0), "2001:db9::1"))
        #expect(!tunnelIpv6RouteContains(route, "not an address"))
        #expect(!tunnelIpv6RouteContains(TunnelIpv6Route(address: "2001:db8::", prefixLength: 129), "2001:db8::1"))
    }

    @Test func neRoutesMirrorTheExclusions() {
        let routes = tunnelIpv6ExcludedRoutes().map { $0.neRoute }
        #expect(routes.map { $0.destinationAddress } == ["fe80::", "fc00::", "ff00::", "::1"])
        #expect(routes.map { $0.destinationNetworkPrefixLength.intValue } == [10, 7, 8, 128])
    }

    // Every input that changes the applied settings changes the signature, and
    // the same inputs always give the same signature.
    @Test func signatureCoversEveryInput() {
        let base = tunnelNetworkSettingsSignature(
            ipv4Address: "10.1.2.3",
            ipv6Address: "fd00:7572:6e65:1::1",
            dnsServers: ["65.49.70.65", "2001:db8::65:49:70:65"],
            mtu: 1420
        )
        #expect(base == "v4=10.1.2.3|v6=fd00:7572:6e65:1::1|dns=65.49.70.65,2001:db8::65:49:70:65|mtu=1420")
        #expect(base == tunnelNetworkSettingsSignature(
            ipv4Address: "10.1.2.3",
            ipv6Address: "fd00:7572:6e65:1::1",
            dnsServers: ["65.49.70.65", "2001:db8::65:49:70:65"],
            mtu: 1420
        ))
        #expect(base != tunnelNetworkSettingsSignature(ipv4Address: "10.1.2.4", ipv6Address: "fd00:7572:6e65:1::1", dnsServers: ["65.49.70.65", "2001:db8::65:49:70:65"], mtu: 1420))
        #expect(base != tunnelNetworkSettingsSignature(ipv4Address: "10.1.2.3", ipv6Address: "fd00:7572:6e65:1::2", dnsServers: ["65.49.70.65", "2001:db8::65:49:70:65"], mtu: 1420))
        #expect(base != tunnelNetworkSettingsSignature(ipv4Address: "10.1.2.3", ipv6Address: nil, dnsServers: ["65.49.70.65", "2001:db8::65:49:70:65"], mtu: 1420))
        #expect(base != tunnelNetworkSettingsSignature(ipv4Address: "10.1.2.3", ipv6Address: "fd00:7572:6e65:1::1", dnsServers: ["65.49.70.65"], mtu: 1420))
        #expect(base != tunnelNetworkSettingsSignature(ipv4Address: "10.1.2.3", ipv6Address: "fd00:7572:6e65:1::1", dnsServers: ["65.49.70.65", "2001:db8::65:49:70:65"], mtu: 1280))
    }

    @Test func signatureSpellsAMissingIpv6InterfaceAsOff() {
        let signature = tunnelNetworkSettingsSignature(ipv4Address: "10.1.2.3", ipv6Address: nil, dnsServers: [], mtu: 1420)
        #expect(signature == "v4=10.1.2.3|v6=off|dns=|mtu=1420")
    }
}
