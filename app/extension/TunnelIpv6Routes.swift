//
//  TunnelIpv6Routes.swift
//  URnetworkVPN
//
//  The tunnel's IPv6 route set and the settings signature (connect/IPV6.md
//  C2). Pure values and free functions, compiled into the extension and into
//  the unit tests, so the exclusions the tunnel installs are the ones the
//  tests check.
//

import Foundation
import NetworkExtension

/// One IPv6 destination prefix, as NEIPv6Route spells it.
struct TunnelIpv6Route: Equatable {
    let address: String
    let prefixLength: Int

    var neRoute: NEIPv6Route {
        NEIPv6Route(destinationAddress: address, networkPrefixLength: NSNumber(value: prefixLength))
    }
}

/// The IPv6 ranges that bypass the tunnel under the ::/0 default route. They
/// mirror the RFC1918 exclusions on IPv4: link-local, unique-local (a home
/// network's own ULA space, which also covers the tunnel interface's own /64
/// -- that prefix carries nothing but this host, so the exclusion costs
/// nothing), multicast, and loopback. Every other IPv6 destination, including
/// the tunnel's own resolver address, goes through the tunnel.
func tunnelIpv6ExcludedRoutes() -> [TunnelIpv6Route] {
    [
        TunnelIpv6Route(address: "fe80::", prefixLength: 10),
        TunnelIpv6Route(address: "fc00::", prefixLength: 7),
        TunnelIpv6Route(address: "ff00::", prefixLength: 8),
        TunnelIpv6Route(address: "::1", prefixLength: 128),
    ]
}

/// Whether an IPv6 literal falls inside a route's prefix. Used by the tests to
/// pin the exclusion set to the addresses it must and must not cover; false
/// for anything that does not parse as IPv6.
func tunnelIpv6RouteContains(_ route: TunnelIpv6Route, _ address: String) -> Bool {
    guard let routeBytes = tunnelIpv6Bytes(route.address),
          let addressBytes = tunnelIpv6Bytes(address),
          0...128 ~= route.prefixLength else {
        return false
    }
    var remaining = route.prefixLength
    for i in 0..<16 {
        if remaining <= 0 {
            return true
        }
        let bits = min(8, remaining)
        let mask = UInt8(truncatingIfNeeded: 0xff << (8 - bits))
        if routeBytes[i] & mask != addressBytes[i] & mask {
            return false
        }
        remaining -= bits
    }
    return true
}

/// Whether the exclusion set routes an address outside the tunnel.
func tunnelIpv6Excluded(_ address: String) -> Bool {
    tunnelIpv6ExcludedRoutes().contains { tunnelIpv6RouteContains($0, address) }
}

private func tunnelIpv6Bytes(_ address: String) -> [UInt8]? {
    var addr = in6_addr()
    guard inet_pton(AF_INET6, address, &addr) == 1 else {
        return nil
    }
    return withUnsafeBytes(of: &addr) { Array($0) }
}

/// The signature the provider compares to decide whether a settings plan is
/// already applied. Every input that changes the NE settings is in it: both
/// tunnel addresses, the DNS servers in order, and the MTU. `ipv6Address` is
/// nil when the tunnel advertises no IPv6 interface.
func tunnelNetworkSettingsSignature(
    ipv4Address: String,
    ipv6Address: String?,
    dnsServers: [String],
    mtu: Int32
) -> String {
    "v4=\(ipv4Address)|v6=\(ipv6Address ?? "off")|dns=\(dnsServers.joined(separator: ","))|mtu=\(mtu)"
}
