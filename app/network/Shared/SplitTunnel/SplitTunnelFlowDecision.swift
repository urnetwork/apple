//
//  SplitTunnelFlowDecision.swift
//  URnetwork
//
//  macOS per-app split tunnel: which flows the transparent proxy takes out
//  of the VPN. The split tunnel system extension (splittunnel/, a
//  NETransparentProxyProvider) sees every new TCP and UDP flow on the Mac.
//  A flow from an excluded app, to a destination the packet tunnel would
//  capture, is relayed by the proxy straight out of the physical interface;
//  every other flow is declined, which hands it back to the network stack
//  unchanged -- into the tunnel, as before.
//
//  The source app is NEFlowMetaData.sourceAppSigningIdentifier, which the
//  system fills from the code signature of the app the flow is attributed to
//  (the app itself for flows that WebKit or nsurlsessiond open on its
//  behalf). An app's own helper processes conventionally sign with the app's
//  identifier plus a suffix ("com.google.Chrome" ->
//  "com.google.Chrome.helper"), so an excluded app also covers identifiers
//  below it -- but only for identifiers of three or more labels, so a short
//  one can never take a whole vendor ("com.apple") out of the tunnel.
//
//  Pure Foundation, so it compiles into the extension targets, the app and
//  the unit tests (which run on the iOS simulator).
//

import Foundation

/// The excluded apps, matched against a flow's source app signing identifier.
struct SplitTunnelAppMatcher: Equatable {

    /// Identifiers this short only ever match exactly (see the file comment).
    static let minimumLabelsForHelpers = 3

    private let exact: Set<String>
    private let withHelpers: Set<String>

    init(excludedApps: [String]) {
        var exact = Set<String>()
        var withHelpers = Set<String>()
        for app in excludedApps {
            let identifier = app.lowercased()
            guard !identifier.isEmpty else {
                continue
            }
            exact.insert(identifier)
            let labels = identifier.split(separator: ".", omittingEmptySubsequences: false)
            if Self.minimumLabelsForHelpers <= labels.count && !labels.contains(where: { $0.isEmpty }) {
                withHelpers.insert(identifier)
            }
        }
        self.exact = exact
        self.withHelpers = withHelpers
    }

    var isEmpty: Bool {
        exact.isEmpty
    }

    func matches(signingIdentifier: String) -> Bool {
        let identifier = signingIdentifier.lowercased()
        guard !identifier.isEmpty else {
            // a system process, or a flow the system could not attribute
            return false
        }
        if exact.contains(identifier) {
            return true
        }
        // walk up the parents: a.b.c.helper.renderer -> a.b.c.helper -> a.b.c
        var candidate = Substring(identifier)
        while let dot = candidate.lastIndex(of: ".") {
            candidate = candidate[..<dot]
            if withHelpers.contains(String(candidate)) {
                return true
            }
        }
        return false
    }
}

/// Whether a destination is one the packet tunnel captures. Everything else
/// already leaves the Mac without the tunnel (the private ranges and
/// link-local are excluded routes, `excludeLocalNetworks` keeps on-link
/// subnets local, loopback never routes), so the proxy declines it and the
/// routing table decides, as it would without the proxy. Forcing such a flow
/// out of the primary interface could only break it: a LAN on another
/// interface, or 100.64.0.0/10 behind another VPN's more specific route.
enum SplitTunnelDestination {

    static func isTunneled(host: String) -> Bool {
        // a scoped IPv6 literal (fe80::1%en0) is link-local by construction
        let address = host.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? host
        if let bytes = ipv4Bytes(address) {
            return isTunneled(ipv4: bytes)
        }
        if let bytes = ipv6Bytes(address) {
            return isTunneled(ipv6: bytes)
        }
        let name = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if name.isEmpty || name == "localhost" || name.hasSuffix(".localhost") {
            return false
        }
        // multicast DNS names resolve on the local link
        if name == "local" || name.hasSuffix(".local") {
            return false
        }
        return true
    }

    static func isTunneled(ipv4 bytes: [UInt8]) -> Bool {
        guard bytes.count == 4 else {
            return false
        }
        switch bytes[0] {
        case 0, 10, 127:
            // "this network", private, loopback
            return false
        case 100 where bytes[1] & 0xc0 == 64:
            // 100.64.0.0/10, shared address space (carrier NAT, overlay VPNs)
            return false
        case 169 where bytes[1] == 254:
            // link-local
            return false
        case 172 where bytes[1] & 0xf0 == 16:
            // 172.16.0.0/12
            return false
        case 192 where bytes[1] == 168:
            return false
        case 224...255:
            // multicast, reserved and the limited broadcast address
            return false
        default:
            return true
        }
    }

    static func isTunneled(ipv6 bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else {
            return false
        }
        // ::ffff:a.b.c.d is an IPv4 destination
        if bytes[0..<10].allSatisfy({ $0 == 0 }) && bytes[10] == 0xff && bytes[11] == 0xff {
            return isTunneled(ipv4: Array(bytes[12..<16]))
        }
        if bytes[0..<15].allSatisfy({ $0 == 0 }) && (bytes[15] == 0 || bytes[15] == 1) {
            // unspecified, loopback
            return false
        }
        if bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80 {
            // fe80::/10 link-local
            return false
        }
        if bytes[0] & 0xfe == 0xfc {
            // fc00::/7 unique local
            return false
        }
        if bytes[0] == 0xff {
            // multicast
            return false
        }
        return true
    }

    private static func ipv4Bytes(_ address: String) -> [UInt8]? {
        var addr = in_addr()
        guard inet_pton(AF_INET, address, &addr) == 1 else {
            return nil
        }
        return withUnsafeBytes(of: &addr) { Array($0) }
    }

    private static func ipv6Bytes(_ address: String) -> [UInt8]? {
        var addr = in6_addr()
        guard inet_pton(AF_INET6, address, &addr) == 1 else {
            return nil
        }
        return withUnsafeBytes(of: &addr) { Array($0) }
    }
}

enum SplitTunnelFlowVerdict: Equatable {
    /// The proxy takes the flow and relays it outside the tunnel.
    case relay
    /// The flow continues as if the proxy did not exist.
    case decline
}

enum SplitTunnelFlowDecision {

    /// - Parameters:
    ///   - signingIdentifier: NEFlowMetaData.sourceAppSigningIdentifier
    ///   - destinationTunneled: whether the flow's remote address is one the
    ///     tunnel captures (`SplitTunnelDestination`); nil when the remote
    ///     endpoint is not an address the proxy can dial
    ///   - isBound: NEAppProxyFlow.isBound. An app that bound its socket to
    ///     an interface chose its path itself, and keeps it.
    static func verdict(
        signingIdentifier: String,
        destinationTunneled: Bool?,
        isBound: Bool,
        matcher: SplitTunnelAppMatcher
    ) -> SplitTunnelFlowVerdict {
        guard matcher.matches(signingIdentifier: signingIdentifier) else {
            return .decline
        }
        guard !isBound else {
            return .decline
        }
        guard destinationTunneled == true else {
            return .decline
        }
        return .relay
    }
}

/// Why a relayed flow could not reach its destination, in the terms the
/// source app understands (NEAppProxyFlowError codes in the extension).
enum SplitTunnelFlowFailure: Equatable {
    case refused
    case timedOut
    case hostUnreachable
    case peerReset
    case aborted

    /// From the POSIX error the outbound connection failed with.
    static func from(posixErrorCode code: Int32) -> SplitTunnelFlowFailure {
        switch code {
        case ECONNREFUSED:
            return .refused
        case ETIMEDOUT:
            return .timedOut
        case EHOSTUNREACH, ENETUNREACH, EHOSTDOWN, ENETDOWN, EADDRNOTAVAIL:
            return .hostUnreachable
        case ECONNRESET, EPIPE:
            return .peerReset
        default:
            return .aborted
        }
    }
}
