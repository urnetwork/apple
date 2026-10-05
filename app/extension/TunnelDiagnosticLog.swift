//
//  TunnelDiagnosticLog.swift
//  URnetworkVPN
//
//  Support lines the packet tunnel extension writes into the logs that "send
//  feedback with logs" uploads: who started the tunnel, the network country it
//  reports (none, on Apple platforms), and the physical network path each time
//  it settles.
//
//  That upload is this process's glog files only: the app asks the extension
//  over the device rpc, and the sdk (DeviceLocal.UploadLogs) zips the
//  extension's own log directory. It carries neither os_log nor the app
//  process's logs. So a line support needs from an upload is written here,
//  through the sdk's LogAppInfo as well as to os_log. The sdk writes one
//  bounded, sanitized glog line per call, "[app][<tag>] <line>".
//
//  Nothing new leaves the device: the lines hold fixed words, interface types
//  and flags only, never an address, a gateway, an interface or network name or
//  an identifier, and the log files leave the device only when the user sends
//  feedback with logs.
//
//  Pure values and free functions with the writers injected, compiled into the
//  extension and into the unit tests (TunnelDiagnosticLogTests).
//

import Foundation
import Network

/// Writes one support line to os_log and to the sdk log. The extension passes
/// `SdkLogAppInfo` as `sdkLog`; both writers may be called from any queue.
struct TunnelDiagnosticLog {
    /// The sdk log tags, each at most 32 of [A-Za-z0-9._-] (sdk LogAppInfo).
    static let tunnelTag = "tunnel"
    static let networkCountryTag = "network-country"
    static let pathTag = "path"

    /// Path lines per tunnel session (TunnelDiagnosticLineFilter).
    static let pathLineLimit = 64

    let osLog: (String) -> Void
    let sdkLog: (_ tag: String, _ line: String) -> Void

    func write(tag: String, line: String) {
        osLog("[\(tag)] \(line)")
        sdkLog(tag, line)
    }
}

/// Decides which of a stream of lines under one tag are written: a line only
/// when it differs from the one before, so a burst of identical updates writes
/// once, and at most `limit` lines, so a flapping network cannot fill the log.
/// The first line past the limit is replaced by one notice, and after it
/// nothing is written. A value per tunnel session, confined to one queue.
struct TunnelDiagnosticLineFilter {
    let limit: Int
    private var lastLine: String?
    private var changeCount = 0

    init(limit: Int) {
        self.limit = limit
    }

    /// The line to write for `line`, or nil to write nothing.
    mutating func admit(_ line: String) -> String? {
        guard line != lastLine else {
            return nil
        }
        lastLine = line
        changeCount += 1
        if changeCount <= limit {
            return line
        }
        if changeCount == limit + 1 {
            return "further changes are not logged this session (limit \(limit))"
        }
        return nil
    }
}

/// The network country line written at each tunnel start. The extension
/// reports no network country on any Apple platform, and the line says why,
/// so a log from a whitelist-only network shows what the extender dials had to
/// go on.
///
/// Android reports the cellular network's country (TelephonyManager
/// .networkCountryIso) with Sdk.setNetworkCountryCode, and the extender dials
/// fall back to it when the operator's extender hint cannot be read (connect
/// ExtenderDirectory.SpoofCountryCode). iOS gives apps no country for the
/// network the device is on: CTCarrier only ever described the SIM's home
/// carrier, is deprecated with no replacement, and returns placeholders ("--",
/// 65535) since iOS 16.4. The locale or region setting is not a network signal
/// and is not reported in its place. A Mac has no cellular network. So the
/// dials draw their names from the list of the operator hint's country, else
/// from the global list.
func tunnelNetworkCountryLogLine(platformHasCellular: Bool) -> String {
    let reason = platformHasCellular
        ? "iOS gives apps no country for the cellular network"
        : "this device has no cellular network"
    return "none reported (\(reason)); the extender spoof list follows the operator hint's country, else the global list"
}

/// The physical network path as its support line describes it: the path's
/// status, why it is unusable, the types of the interfaces it uses, the
/// cellular radio technology and the path's flags. No addresses, gateways or
/// names.
struct TunnelPathDiagnostic: Equatable {
    let status: NWPath.Status
    /// Why the path cannot be used, nil when it can.
    let unsatisfiedReason: NWPath.UnsatisfiedReason?
    let interfaceTypes: [NWInterface.InterfaceType]
    /// The radio access technology of the active cellular service as
    /// CTTelephonyNetworkInfo names it (tunnelActiveCellularTypes): empty off
    /// cellular and on macOS.
    let cellularTypes: [String]
    let expensive: Bool
    let constrained: Bool
    let supportsIpv4: Bool
    let supportsIpv6: Bool
    let supportsDns: Bool

    /// At most this many radio technologies are named (a dual-SIM device has
    /// two services).
    static let cellularTypeLimit = 4

    /// Reads the fields the line uses from `path`, nothing else.
    init(path: NWPath, cellularTypes: [String]) {
        self.init(
            status: path.status,
            unsatisfiedReason: path.status == .satisfied ? nil : path.unsatisfiedReason,
            interfaceTypes: path.availableInterfaces.map(\.type).filter { path.usesInterfaceType($0) },
            cellularTypes: cellularTypes,
            expensive: path.isExpensive,
            constrained: path.isConstrained,
            supportsIpv4: path.supportsIPv4,
            supportsIpv6: path.supportsIPv6,
            supportsDns: path.supportsDNS
        )
    }

    init(
        status: NWPath.Status,
        unsatisfiedReason: NWPath.UnsatisfiedReason?,
        interfaceTypes: [NWInterface.InterfaceType],
        cellularTypes: [String],
        expensive: Bool,
        constrained: Bool,
        supportsIpv4: Bool,
        supportsIpv6: Bool,
        supportsDns: Bool
    ) {
        self.status = status
        self.unsatisfiedReason = unsatisfiedReason
        self.interfaceTypes = interfaceTypes
        self.cellularTypes = cellularTypes
        self.expensive = expensive
        self.constrained = constrained
        self.supportsIpv4 = supportsIpv4
        self.supportsIpv6 = supportsIpv6
        self.supportsDns = supportsDns
    }

    /// e.g. "status=satisfied interfaces=cellular cellular=lte expensive=true
    /// constrained=false ipv4=true ipv6=true dns=true", one line, a few hundred
    /// bytes at most.
    var line: String {
        var fields = ["status=\(tunnelPathStatusName(status))"]
        if let unsatisfiedReason {
            fields.append("reason=\(tunnelPathUnsatisfiedReasonName(unsatisfiedReason))")
        }
        let interfaceNames = Self.interfaceNameOrder.filter { name in
            interfaceTypes.contains { tunnelInterfaceTypeName($0) == name }
        }
        fields.append("interfaces=\(interfaceNames.isEmpty ? "none" : interfaceNames.joined(separator: ","))")
        var technologies: [String] = []
        for cellularType in cellularTypes {
            let name = tunnelRadioAccessTechnologyName(cellularType)
            if !name.isEmpty && !technologies.contains(name) {
                technologies.append(name)
            }
        }
        if !technologies.isEmpty {
            fields.append("cellular=\(technologies.prefix(Self.cellularTypeLimit).joined(separator: ","))")
        }
        fields.append("expensive=\(expensive)")
        fields.append("constrained=\(constrained)")
        fields.append("ipv4=\(supportsIpv4)")
        fields.append("ipv6=\(supportsIpv6)")
        fields.append("dns=\(supportsDns)")
        return fields.joined(separator: " ")
    }

    // a fixed order, so the same path always gives the same line
    private static let interfaceNameOrder = ["wifi", "cellular", "wired", "other", "loopback"]
}

func tunnelPathStatusName(_ status: NWPath.Status) -> String {
    switch status {
    case .satisfied: return "satisfied"
    case .unsatisfied: return "unsatisfied"
    case .requiresConnection: return "requires-connection"
    @unknown default: return "unknown"
    }
}

/// Network's reasons: cellular-denied and wifi-denied, the user has disabled
/// that network; local-network-denied, the user has disabled local network
/// access; vpn-inactive, a required VPN is not active; not-available, no reason
/// is given.
func tunnelPathUnsatisfiedReasonName(_ reason: NWPath.UnsatisfiedReason) -> String {
    if #available(iOS 17.0, macOS 14.0, *), reason == .vpnInactive {
        return "vpn-inactive"
    }
    switch reason {
    case .notAvailable: return "not-available"
    case .cellularDenied: return "cellular-denied"
    case .wifiDenied: return "wifi-denied"
    case .localNetworkDenied: return "local-network-denied"
    default: return "other"
    }
}

func tunnelInterfaceTypeName(_ type: NWInterface.InterfaceType) -> String {
    switch type {
    case .wifi: return "wifi"
    case .cellular: return "cellular"
    case .wiredEthernet: return "wired"
    case .loopback: return "loopback"
    case .other: return "other"
    @unknown default: return "other"
    }
}

/// A radio access technology as the line names it: the CoreTelephony constant
/// (CTRadioAccessTechnologyLTE, CTRadioAccessTechnologyNRNSA, ...) without its
/// prefix, in lower case ascii letters and digits, at most 16 of them; empty
/// when nothing is left.
func tunnelRadioAccessTechnologyName(_ technology: String) -> String {
    let prefix = "CTRadioAccessTechnology"
    let name = technology.hasPrefix(prefix) ? technology.dropFirst(prefix.count) : technology[...]
    var scalars = String.UnicodeScalarView()
    for scalar in name.unicodeScalars where scalars.count < 16 {
        switch scalar {
        case "a"..."z", "0"..."9":
            scalars.append(scalar)
        case "A"..."Z":
            scalars.append(Unicode.Scalar(scalar.value + 32)!)
        default:
            break
        }
    }
    return String(scalars)
}
