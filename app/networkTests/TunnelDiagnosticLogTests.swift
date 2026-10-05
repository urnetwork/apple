//
//  TunnelDiagnosticLogTests.swift
//  networkTests
//

import Foundation
import Network
import Testing
@testable import URnetwork

/**
 * The support lines the packet tunnel extension writes into the uploaded logs
 * through the sdk's LogAppInfo (TunnelDiagnosticLog): who started the tunnel,
 * why no network country is reported, and the settled network path.
 */
struct TunnelDiagnosticLogTests {

    private static func path(
        status: NWPath.Status = .satisfied,
        reason: NWPath.UnsatisfiedReason? = nil,
        interfaces: [NWInterface.InterfaceType] = [.wifi],
        cellular: [String] = [],
        expensive: Bool = false,
        constrained: Bool = false,
        ipv4: Bool = true,
        ipv6: Bool = true,
        dns: Bool = true
    ) -> TunnelPathDiagnostic {
        TunnelPathDiagnostic(
            status: status,
            unsatisfiedReason: reason,
            interfaceTypes: interfaces,
            cellularTypes: cellular,
            expensive: expensive,
            constrained: constrained,
            supportsIpv4: ipv4,
            supportsIpv6: ipv6,
            supportsDns: dns
        )
    }

    // MARK: the writers

    // the sdk log is the one the upload carries; os_log gets the same line
    @Test func aLineReachesTheSdkLogUnderItsTag() {
        var sdkLines: [String] = []
        var osLines: [String] = []
        let log = TunnelDiagnosticLog(
            osLog: { osLines.append($0) },
            sdkLog: { tag, line in sdkLines.append("\(tag)|\(line)") }
        )
        log.write(tag: TunnelDiagnosticLog.pathTag, line: "status=satisfied")
        #expect(sdkLines == ["path|status=satisfied"])
        #expect(osLines == ["[path] status=satisfied"])
    }

    // the sdk keeps a tag only as at most 32 of [A-Za-z0-9._-]
    @Test func theTagsAreOnesTheSdkKeepsWhole() {
        let tags = [TunnelDiagnosticLog.tunnelTag, TunnelDiagnosticLog.networkCountryTag, TunnelDiagnosticLog.pathTag]
        #expect(tags == ["tunnel", "network-country", "path"])
        for tag in tags {
            #expect(tag.count <= 32)
            #expect(tag.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-").contains($0) })
        }
    }

    // MARK: the filter

    @Test func anUnchangedLineIsWrittenOnce() {
        var filter = TunnelDiagnosticLineFilter(limit: 8)
        #expect(filter.admit("wifi") == "wifi")
        #expect(filter.admit("wifi") == nil)
        #expect(filter.admit("cellular") == "cellular")
        #expect(filter.admit("cellular") == nil)
        #expect(filter.admit("wifi") == "wifi")
    }

    // a flapping network writes up to the limit, one notice, then nothing
    @Test func aFlappingNetworkStopsAtTheLimit() {
        var filter = TunnelDiagnosticLineFilter(limit: 3)
        let written = (0..<10).compactMap { filter.admit($0 % 2 == 0 ? "wifi" : "cellular") }
        #expect(written == ["wifi", "cellular", "wifi", "further changes are not logged this session (limit 3)"])
        #expect(TunnelDiagnosticLog.pathLineLimit == 64)
    }

    // MARK: the path line

    @Test func theLineOfAWifiPath() {
        #expect(
            Self.path(ipv6: false).line
                == "status=satisfied interfaces=wifi expensive=false constrained=false ipv4=true ipv6=false dns=true"
        )
    }

    // on cellular the line names the radio technology of the data service
    @Test func theLineOfACellularPathNamesTheRadio() {
        let line = Self.path(
            interfaces: [.cellular], cellular: ["CTRadioAccessTechnologyNRNSA"], expensive: true, constrained: true
        ).line
        #expect(line == "status=satisfied interfaces=cellular cellular=nrnsa expensive=true constrained=true ipv4=true ipv6=true dns=true")
    }

    // an unusable path says why, e.g. cellular data switched off for the app
    @Test func theLineOfAnUnusablePathSaysWhy() {
        let line = Self.path(
            status: .unsatisfied, reason: .cellularDenied, interfaces: [], ipv4: false, ipv6: false, dns: false
        ).line
        #expect(line == "status=unsatisfied reason=cellular-denied interfaces=none expensive=false constrained=false ipv4=false ipv6=false dns=false")
    }

    // the same path always gives the same line, so the filter can drop repeats
    @Test func theInterfacesAreNamedOnceInAFixedOrder() {
        let line = Self.path(interfaces: [.cellular, .wiredEthernet, .wifi, .cellular]).line
        #expect(line.contains(" interfaces=wifi,cellular,wired "))
        #expect(line == Self.path(interfaces: [.wifi, .wiredEthernet, .cellular]).line)
    }

    @Test func everyStatusReasonAndInterfaceHasAName() {
        #expect(tunnelPathStatusName(.satisfied) == "satisfied")
        #expect(tunnelPathStatusName(.unsatisfied) == "unsatisfied")
        #expect(tunnelPathStatusName(.requiresConnection) == "requires-connection")
        #expect(tunnelPathUnsatisfiedReasonName(.notAvailable) == "not-available")
        #expect(tunnelPathUnsatisfiedReasonName(.cellularDenied) == "cellular-denied")
        #expect(tunnelPathUnsatisfiedReasonName(.wifiDenied) == "wifi-denied")
        #expect(tunnelPathUnsatisfiedReasonName(.localNetworkDenied) == "local-network-denied")
        if #available(iOS 17.0, macOS 14.0, *) {
            #expect(tunnelPathUnsatisfiedReasonName(.vpnInactive) == "vpn-inactive")
        }
        #expect(tunnelInterfaceTypeName(.wifi) == "wifi")
        #expect(tunnelInterfaceTypeName(.cellular) == "cellular")
        #expect(tunnelInterfaceTypeName(.wiredEthernet) == "wired")
        #expect(tunnelInterfaceTypeName(.loopback) == "loopback")
        #expect(tunnelInterfaceTypeName(.other) == "other")
    }

    // CoreTelephony's constants without the prefix; anything else is cut down
    // to lower case letters and digits, so it cannot split or forge a line
    @Test func radioTechnologiesAreShortAndClean() {
        #expect(tunnelRadioAccessTechnologyName("CTRadioAccessTechnologyLTE") == "lte")
        #expect(tunnelRadioAccessTechnologyName("CTRadioAccessTechnologyNR") == "nr")
        #expect(tunnelRadioAccessTechnologyName("CTRadioAccessTechnologyWCDMA") == "wcdma")
        #expect(tunnelRadioAccessTechnologyName("CTRadioAccessTechnologyeHRPD") == "ehrpd")
        #expect(tunnelRadioAccessTechnologyName("5g") == "5g")
        #expect(tunnelRadioAccessTechnologyName("lte\n[app][forged] x") == "lteappforgedx")
        #expect(tunnelRadioAccessTechnologyName(String(repeating: "x", count: 100)) == String(repeating: "x", count: 16))
        #expect(tunnelRadioAccessTechnologyName("é—\u{2028}") == "")
    }

    // whatever the radio reports, the line stays short and holds only the
    // fields' own words: no address, name or identifier can reach it
    @Test func thePathLineIsBoundedAndClean() {
        let line = Self.path(
            interfaces: [.wifi, .cellular, .wiredEthernet, .other, .loopback],
            cellular: (0..<50).map { "CTRadioAccessTechnology\($0)\(String(repeating: "Z", count: 40))\n10.0.0.1" }
        ).line
        #expect(line.utf8.count < 300)
        #expect(line.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789 =,-").contains($0) })
        let cellular = line.split(separator: " ").first { $0.hasPrefix("cellular=") }
        #expect(cellular?.split(separator: ",").count == TunnelPathDiagnostic.cellularTypeLimit)
    }

    // MARK: the network country

    // no network country is reported on Apple platforms -- not the locale's
    // region in its place -- and the line says why
    @Test func theNetworkCountryLineReportsNone() {
        #expect(
            tunnelNetworkCountryLogLine(platformHasCellular: true)
                == "none reported (iOS gives apps no country for the cellular network); the extender spoof list follows the operator hint's country, else the global list"
        )
        #expect(
            tunnelNetworkCountryLogLine(platformHasCellular: false)
                == "none reported (this device has no cellular network); the extender spoof list follows the operator hint's country, else the global list"
        )
    }

    // MARK: the start source

    // a start without options is the system's (VPN On Demand, or Settings)
    @Test func theStartSourceNamesWhoStartedTheTunnel() {
        #expect(TunnelIntentStore.startSource(options: nil) == TunnelIntentStore.sourceSystem)
        for source in [TunnelIntentStore.sourceApp, TunnelIntentStore.sourceControl, TunnelIntentStore.sourceWidget] {
            #expect(TunnelIntentStore.startSource(options: TunnelIntentStore.startOptions(source: source)) == source)
        }
        #expect(TunnelIntentStore.startOptions(source: "app") == ["network.ur.start-source": "app" as NSString])
    }

    // only the known names come back, never other text the options hold
    @Test func anUnknownStartSourceIsNotEchoed() {
        #expect(TunnelIntentStore.startSource(options: [:]) == "unknown")
        #expect(TunnelIntentStore.startSource(options: ["other": "app" as NSString]) == "unknown")
        #expect(TunnelIntentStore.startSource(options: TunnelIntentStore.startOptions(source: "app\n[app][forged]")) == "unknown")
        #expect(TunnelIntentStore.startSource(options: [TunnelIntentStore.startSourceOptionKey: NSNumber(value: 1)]) == "unknown")
    }

    // MARK: the wiring

    // …/apple/app/networkTests/TunnelDiagnosticLogTests.swift -> …/apple/app
    private static let appRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static func source(_ path: String) throws -> String {
        try String(contentsOf: appRoot.appendingPathComponent(path), encoding: .utf8)
    }

    // the extension writes through the sdk's LogAppInfo, the only way into the
    // uploaded logs: the start lines at each start, and the path once it
    // settles, usable or not
    @Test func theExtensionWritesTheLinesThroughTheSdkLog() throws {
        let text = try Self.source("extension/PacketTunnelProvider.swift")
        #expect(text.contains("sdkLog: { tag, line in SdkLogAppInfo(tag, line) }"))
        #expect(text.contains(#"line: "start source=\(TunnelIntentStore.startSource(options: options))""#))
        #expect(text.contains("line: tunnelNetworkCountryLogLine(platformHasCellular: platformHasCellular)"))
        #expect(text.contains("TunnelDiagnosticLineFilter(limit: TunnelDiagnosticLog.pathLineLimit)"))
        #expect(text.components(separatedBy: "writePathLine(diagnostic)").count - 1 == 2)
    }

    // the app and the widget name themselves when they start the tunnel, so a
    // start without a name is the system's
    @Test func theAppAndTheWidgetNameTheirStarts() throws {
        let app = try Self.source("network/Shared/VPNProfileSystem.swift")
        #expect(app.contains("options: TunnelIntentStore.startOptions(source: TunnelIntentStore.sourceApp)"))
        #expect(!app.contains("startVPNTunnel()"))
        let widget = try Self.source("widgets/Control/TunnelControlSupport.swift")
        #expect(widget.contains("options: TunnelIntentStore.startOptions(source: source)"))
    }
}
