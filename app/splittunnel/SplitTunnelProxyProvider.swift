//
//  SplitTunnelProxyProvider.swift
//  URnetworkSplitTunnel (macOS split tunnel system extension)
//
//  The per-app split tunnel. A transparent proxy sees every new outbound TCP
//  and UDP flow on the Mac before routing does. A flow from an app the user
//  excluded (by signing identifier, see SplitTunnelFlowDecision.swift) to a
//  destination the packet tunnel would capture is taken here and relayed by
//  a connection of this extension's own, bound to the physical interface, so
//  it leaves the Mac outside the tunnel. Every other flow is declined, which
//  for a NETransparentProxyProvider means the flow continues exactly as if
//  the proxy were not there -- into the tunnel, as before.
//
//  The excluded apps arrive in NETunnelProviderProtocol.providerConfiguration
//  when the proxy starts and as a provider message when the list changes
//  (SplitTunnelProxyConfiguration). The app starts the proxy while the user
//  wants the VPN connected and stops it otherwise
//  (SplitTunnelProxyController.swift).
//
//  The relays bypass the tunnel by binding: the packet tunnel installs
//  default routes but does not set includeAllNetworks, so a socket bound to
//  the physical interface keeps that interface's scoped route. DNS is not
//  proxied -- the system resolves names before the flow reaches here (and
//  through the tunnel's resolver), so a relay always dials an address.
//
//  Built on the macOS 15 flow API (Network.framework endpoints); the target's
//  deployment target is 15.0 and the app offers excluded apps only there.
//

import Foundation
import Network
import NetworkExtension
import OSLog

/// The transparent proxy: relays the excluded apps' flows and declines every
/// other flow (see the file comment).
final class SplitTunnelProxyProvider: NETransparentProxyProvider, NEAppProxyUDPFlowHandling {

    private let logger = Logger(subsystem: "network.ur.splittunnel", category: "SplitTunnelProxy")

    /// every relay's state changes on this one serial queue
    private let queue = DispatchQueue(label: "network.ur.splittunnel.relays")
    private let state = SplitTunnelProxyState()
    private var relays: [ObjectIdentifier: SplitTunnelRelay] = [:]
    private var pathMonitor: NWPathMonitor?

    /// Takes the list from the configuration, follows the physical interface
    /// and asks for every outbound TCP and UDP flow.
    override func startProxy(options: [String: Any]? = nil, completionHandler: @escaping (Error?) -> Void) {
        let configuration = SplitTunnelProxyConfiguration(
            providerConfiguration: (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration
        ) ?? .empty
        apply(configuration)

        // the physical interfaces, best first; the tunnel's utun is "other"
        let monitor = NWPathMonitor(prohibitedInterfaceTypes: [.other])
        monitor.pathUpdateHandler = { [weak self] path in
            self?.state.setInterface(path.status == .satisfied ? path.availableInterfaces.first : nil)
        }
        monitor.start(queue: queue)
        pathMonitor = monitor

        // every outbound TCP and UDP flow (nil networks match all but loopback)
        let settings = NETransparentProxyNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.includedNetworkRules = [
            NENetworkRule(
                remoteNetworkEndpoint: nil,
                remotePrefix: 0,
                localNetworkEndpoint: nil,
                localPrefix: 0,
                protocol: .TCP,
                direction: .outbound
            ),
            NENetworkRule(
                remoteNetworkEndpoint: nil,
                remotePrefix: 0,
                localNetworkEndpoint: nil,
                localPrefix: 0,
                protocol: .UDP,
                direction: .outbound
            ),
        ]
        setTunnelNetworkSettings(settings) { [weak self] error in
            if let error {
                self?.logger.error("[SplitTunnelProxy]start failed: \(error.localizedDescription, privacy: .public)")
            } else {
                self?.logger.info("[SplitTunnelProxy]started with \(configuration.excludedApps.count, privacy: .public) excluded apps")
            }
            completionHandler(error)
        }
    }

    /// Stops following the interface and closes every relay.
    override func stopProxy(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        logger.info("[SplitTunnelProxy]stop reason=\(reason.rawValue, privacy: .public)")
        queue.async { [self] in
            pathMonitor?.cancel()
            pathMonitor = nil
            let active = Array(relays.values)
            relays.removeAll()
            for relay in active {
                relay.cancel()
            }
            completionHandler()
        }
    }

    /// The app hands over a changed list while the proxy runs.
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
        if let configuration = SplitTunnelProxyConfiguration(messageData: messageData) {
            apply(configuration)
        } else {
            logger.error("[SplitTunnelProxy]ignored an unreadable app message")
        }
        completionHandler?(nil)
    }

    /// A new TCP flow: relayed, or declined by returning false.
    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        // UDP flows arrive through handleNewUDPFlow
        guard let tcpFlow = flow as? NEAppProxyTCPFlow else {
            return false
        }
        let endpoint = tcpFlow.remoteFlowEndpoint
        guard verdict(flow: flow, remoteEndpoint: endpoint) == .relay else {
            return false
        }
        let relay = SplitTunnelTCPRelay(
            flow: tcpFlow,
            remoteEndpoint: endpoint,
            interface: state.interface(),
            queue: queue,
            logger: logger
        )
        start(relay, signingIdentifier: flow.metaData.sourceAppSigningIdentifier)
        return true
    }

    /// A new UDP flow: relayed, or declined by returning false.
    func handleNewUDPFlow(_ flow: NEAppProxyUDPFlow, initialRemoteFlowEndpoint remoteEndpoint: Network.NWEndpoint) -> Bool {
        guard verdict(flow: flow, remoteEndpoint: remoteEndpoint) == .relay else {
            return false
        }
        let relay = SplitTunnelUDPRelay(
            flow: flow,
            interface: state.interface(),
            queue: queue,
            logger: logger
        )
        start(relay, signingIdentifier: flow.metaData.sourceAppSigningIdentifier)
        return true
    }

    /// The shared decision for a new flow, against the current list.
    private func verdict(flow: NEAppProxyFlow, remoteEndpoint: Network.NWEndpoint) -> SplitTunnelFlowVerdict {
        SplitTunnelFlowDecision.verdict(
            signingIdentifier: flow.metaData.sourceAppSigningIdentifier,
            destinationTunneled: Self.destinationTunneled(remoteEndpoint),
            isBound: flow.isBound,
            matcher: state.matcher()
        )
    }

    /// nil for an endpoint that is not an address (the system resolves
    /// names before a transparent proxy sees the flow)
    static func destinationTunneled(_ endpoint: Network.NWEndpoint) -> Bool? {
        guard case .hostPort(let host, _) = endpoint else {
            return nil
        }
        switch host {
        case .ipv4(let address):
            return SplitTunnelDestination.isTunneled(ipv4: Array(address.rawValue))
        case .ipv6(let address):
            return SplitTunnelDestination.isTunneled(ipv6: Array(address.rawValue))
        case .name:
            return nil
        @unknown default:
            return nil
        }
    }

    /// Keeps the relay until it finishes, so a stop or a changed list can
    /// close it.
    private func start(_ relay: SplitTunnelRelay, signingIdentifier: String) {
        queue.async { [self] in
            let key = ObjectIdentifier(relay)
            relays[key] = relay
            relay.start(signingIdentifier: signingIdentifier) { [weak self] in
                // on `queue`
                self?.relays.removeValue(forKey: key)
            }
        }
    }

    /// New flows follow the new list at once; relays of apps that are no
    /// longer excluded are closed, so the app reconnects -- through the
    /// tunnel. Leaving them open would keep an app the user just put back
    /// on the VPN outside it for as long as its connections live.
    private func apply(_ configuration: SplitTunnelProxyConfiguration) {
        let matcher = SplitTunnelAppMatcher(excludedApps: configuration.excludedApps)
        state.setMatcher(matcher)
        queue.async { [self] in
            for relay in relays.values where !matcher.matches(signingIdentifier: relay.signingIdentifier) {
                relay.cancel()
            }
        }
    }
}

/// What the flow callbacks (on the system's threads) read and the app
/// message and the path monitor write.
private final class SplitTunnelProxyState {

    private let lock = NSLock()
    private var currentMatcher = SplitTunnelAppMatcher(excludedApps: [])
    private var currentInterface: NWInterface?

    /// The excluded apps new flows are matched against.
    func matcher() -> SplitTunnelAppMatcher {
        lock.lock()
        defer { lock.unlock() }
        return currentMatcher
    }

    /// A changed list; new flows follow it at once.
    func setMatcher(_ matcher: SplitTunnelAppMatcher) {
        lock.lock()
        defer { lock.unlock() }
        currentMatcher = matcher
    }

    /// The physical interface new relays bind to; nil while there is none.
    func interface() -> NWInterface? {
        lock.lock()
        defer { lock.unlock() }
        return currentInterface
    }

    /// Set by the path monitor: its best physical interface, or nil.
    func setInterface(_ interface: NWInterface?) {
        lock.lock()
        defer { lock.unlock() }
        currentInterface = interface
    }
}
