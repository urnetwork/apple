//
//  SplitTunnelRelays.swift
//  URnetworkSplitTunnel (macOS split tunnel system extension)
//
//  A relay carries one excluded app's flow over a connection of this
//  extension's own, outside the tunnel: TCP as a byte stream with both
//  half-closes passed through, UDP as datagrams to each destination the app
//  sends to. A relay's state only changes on the provider's serial queue;
//  the flow callbacks arrive on the system's threads and hop onto it, the
//  connection callbacks are delivered on it.
//

import Foundation
import Network
import NetworkExtension
import OSLog

protocol SplitTunnelRelay: AnyObject {
    /// the source app, for closing the relay when the app is no longer
    /// excluded
    var signingIdentifier: String { get }
    /// on the relay queue; `onFinish` runs once, on the relay queue, when the
    /// relay has closed both sides
    func start(signingIdentifier: String, onFinish: @escaping () -> Void)
    /// on the relay queue
    func cancel()
}

enum SplitTunnelRelayParameters {

    /// The connection leaves through the physical interface: utun is the
    /// "other" interface type, and a socket bound to an interface keeps that
    /// interface's scoped route under the tunnel's default route.
    static func tcp(interface: NWInterface?) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        // the app already chose how to batch its writes
        tcp.noDelay = true
        tcp.connectionTimeout = 30
        let parameters = NWParameters(tls: nil, tcp: tcp)
        bypassTunnel(parameters, interface: interface)
        return parameters
    }

    static func udp(interface: NWInterface?) -> NWParameters {
        let parameters = NWParameters.udp
        bypassTunnel(parameters, interface: interface)
        return parameters
    }

    private static func bypassTunnel(_ parameters: NWParameters, interface: NWInterface?) {
        parameters.prohibitedInterfaceTypes = [.other]
        if let interface {
            parameters.requiredInterface = interface
        }
    }

    /// What the source app sees when its relayed connection fails.
    static func flowError(_ error: Error) -> NSError {
        let failure: SplitTunnelFlowFailure
        if let networkError = error as? NWError {
            switch networkError {
            case .posix(let code):
                failure = SplitTunnelFlowFailure.from(posixErrorCode: code.rawValue)
            case .dns:
                failure = .hostUnreachable
            default:
                failure = .aborted
            }
        } else if (error as NSError).domain == NEAppProxyErrorDomain {
            return error as NSError
        } else {
            failure = .aborted
        }
        let code: NEAppProxyFlowError.Code
        switch failure {
        case .refused:
            code = .refused
        case .timedOut:
            code = .timedOut
        case .hostUnreachable:
            code = .hostUnreachable
        case .peerReset:
            code = .peerReset
        case .aborted:
            code = .aborted
        }
        return NSError(domain: NEAppProxyErrorDomain, code: code.rawValue)
    }
}

final class SplitTunnelTCPRelay: SplitTunnelRelay {

    private static let readSize = 128 * 1024

    private let flow: NEAppProxyTCPFlow
    private let connection: NWConnection
    private let interface: NWInterface?
    private let queue: DispatchQueue
    private let logger: Logger

    private(set) var signingIdentifier = ""
    private var onFinish: (() -> Void)?
    private var opened = false
    private var finished = false
    /// the app shut its sending side (and the FIN went on to the remote)
    private var appDone = false
    /// the remote shut its sending side (and the flow's write side is closed)
    private var remoteDone = false

    init(
        flow: NEAppProxyTCPFlow,
        remoteEndpoint: Network.NWEndpoint,
        interface: NWInterface?,
        queue: DispatchQueue,
        logger: Logger
    ) {
        self.flow = flow
        self.interface = interface
        self.queue = queue
        self.logger = logger
        self.connection = NWConnection(to: remoteEndpoint, using: SplitTunnelRelayParameters.tcp(interface: interface))
    }

    func start(signingIdentifier: String, onFinish: @escaping () -> Void) {
        self.signingIdentifier = signingIdentifier
        self.onFinish = onFinish
        connection.stateUpdateHandler = { [weak self] state in
            self?.connectionStateChanged(state)
        }
        // the flow is opened only once the remote accepted, so a refused or
        // unreachable destination reaches the app as its own connect failing
        connection.start(queue: queue)
    }

    func cancel() {
        finish(error: nil)
    }

    private func connectionStateChanged(_ state: NWConnection.State) {
        switch state {
        case .ready:
            guard !opened, !finished else {
                return
            }
            opened = true
            if let interface {
                flow.interface = interface
            }
            flow.open(withLocalFlowEndpoint: nil) { [weak self] error in
                guard let self else {
                    return
                }
                self.queue.async {
                    guard !self.finished else {
                        return
                    }
                    if let error {
                        self.finish(error: error)
                        return
                    }
                    self.pumpAppToRemote()
                    self.pumpRemoteToApp()
                }
            }
        case .waiting(let error), .failed(let error):
            // waiting means no viable path; a transparent relay fails fast
            // instead of holding the app's connect open
            finish(error: error)
        case .cancelled:
            finish(error: nil)
        case .setup, .preparing:
            break
        @unknown default:
            break
        }
    }

    private func pumpAppToRemote() {
        flow.readData { [weak self] data, error in
            guard let self else {
                return
            }
            self.queue.async {
                guard !self.finished else {
                    return
                }
                if let error {
                    self.finish(error: error)
                    return
                }
                guard let data, !data.isEmpty else {
                    // the app shut its sending side: pass the FIN on
                    self.appDone = true
                    self.connection.send(
                        content: nil,
                        contentContext: .finalMessage,
                        isComplete: true,
                        completion: .contentProcessed { _ in }
                    )
                    self.finishIfBothDone()
                    return
                }
                // the connection holds the completion only until it runs
                // (cancel runs it too), so the capture does not outlive it
                self.connection.send(content: data, completion: .contentProcessed { error in
                    // on the relay queue
                    guard !self.finished else {
                        return
                    }
                    if let error {
                        self.finish(error: error)
                        return
                    }
                    self.pumpAppToRemote()
                })
            }
        }
    }

    private func pumpRemoteToApp() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.readSize) { [weak self] data, _, isComplete, error in
            // on the relay queue
            guard let self, !self.finished else {
                return
            }
            guard let data, !data.isEmpty else {
                self.remoteReceived(isComplete: isComplete, error: error)
                return
            }
            // the next receive waits for the app to take this one
            self.flow.write(data) { [weak self] writeError in
                guard let self else {
                    return
                }
                self.queue.async {
                    guard !self.finished else {
                        return
                    }
                    if let writeError {
                        self.finish(error: writeError)
                        return
                    }
                    self.remoteReceived(isComplete: isComplete, error: error)
                }
            }
        }
    }

    private func remoteReceived(isComplete: Bool, error: NWError?) {
        if isComplete {
            remoteDone = true
            flow.closeWriteWithError(nil)
            finishIfBothDone()
        } else if let error {
            finish(error: error)
        } else {
            pumpRemoteToApp()
        }
    }

    private func finishIfBothDone() {
        if appDone && remoteDone {
            finish(error: nil)
        }
    }

    private func finish(error: Error?) {
        guard !finished else {
            return
        }
        finished = true
        if let error {
            logger.debug("[SplitTunnelProxy]tcp relay closed: \(error.localizedDescription, privacy: .public)")
        }
        connection.stateUpdateHandler = nil
        connection.cancel()
        let flowError = error.map(SplitTunnelRelayParameters.flowError)
        flow.closeReadWithError(flowError)
        if !remoteDone {
            flow.closeWriteWithError(flowError)
        }
        onFinish?()
        onFinish = nil
    }
}

final class SplitTunnelUDPRelay: SplitTunnelRelay {

    /// distinct destinations one flow may send to
    static let maximumDestinations = 64
    /// a flow with no datagram either way for this long is closed
    static let idleTimeout: TimeInterval = 300

    private let flow: NEAppProxyUDPFlow
    private let interface: NWInterface?
    private let queue: DispatchQueue
    private let logger: Logger

    private(set) var signingIdentifier = ""
    private var onFinish: (() -> Void)?
    private var finished = false
    private var connections: [Network.NWEndpoint: NWConnection] = [:]
    private var lastActivity = Date()
    private var idleTimer: DispatchSourceTimer?

    init(
        flow: NEAppProxyUDPFlow,
        interface: NWInterface?,
        queue: DispatchQueue,
        logger: Logger
    ) {
        self.flow = flow
        self.interface = interface
        self.queue = queue
        self.logger = logger
    }

    func start(signingIdentifier: String, onFinish: @escaping () -> Void) {
        self.signingIdentifier = signingIdentifier
        self.onFinish = onFinish
        if let interface {
            flow.interface = interface
        }
        flow.open(withLocalFlowEndpoint: nil) { [weak self] error in
            guard let self else {
                return
            }
            self.queue.async {
                guard !self.finished else {
                    return
                }
                if let error {
                    self.finish(error: error)
                    return
                }
                self.startIdleTimer()
                self.readFromApp()
            }
        }
    }

    func cancel() {
        finish(error: nil)
    }

    private func readFromApp() {
        flow.readDatagrams { [weak self] datagrams, error in
            guard let self else {
                return
            }
            self.queue.async {
                guard !self.finished else {
                    return
                }
                if let error {
                    self.finish(error: error)
                    return
                }
                guard let datagrams, !datagrams.isEmpty else {
                    // the app closed its socket
                    self.finish(error: nil)
                    return
                }
                self.lastActivity = Date()
                for (datagram, endpoint) in datagrams {
                    self.send(datagram, to: endpoint)
                }
                self.readFromApp()
            }
        }
    }

    private func send(_ datagram: Data, to endpoint: Network.NWEndpoint) {
        let connection: NWConnection
        if let existing = connections[endpoint] {
            connection = existing
        } else {
            guard connections.count < Self.maximumDestinations else {
                // dropped, as a congested path would
                return
            }
            connection = connect(to: endpoint)
        }
        connection.send(content: datagram, completion: .contentProcessed { _ in })
    }

    private func connect(to endpoint: Network.NWEndpoint) -> NWConnection {
        // a destination the tunnel does not capture (a LAN peer) keeps the
        // route the system would give it; only tunneled ones are pinned to
        // the physical interface
        let tunneled = SplitTunnelProxyProvider.destinationTunneled(endpoint) ?? false
        let connection = NWConnection(
            to: endpoint,
            using: SplitTunnelRelayParameters.udp(interface: tunneled ? interface : nil)
        )
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            // on the relay queue
            guard let self, let connection else {
                return
            }
            switch state {
            case .waiting, .failed, .cancelled:
                if self.connections[endpoint] === connection {
                    self.connections.removeValue(forKey: endpoint)
                }
                connection.stateUpdateHandler = nil
                connection.cancel()
            default:
                break
            }
        }
        connections[endpoint] = connection
        connection.start(queue: queue)
        receiveFromRemote(connection, endpoint: endpoint)
        return connection
    }

    private func receiveFromRemote(_ connection: NWConnection, endpoint: Network.NWEndpoint) {
        connection.receiveMessage { [weak self, weak connection] data, _, _, error in
            // on the relay queue
            guard let self, let connection, !self.finished else {
                return
            }
            if let data, !data.isEmpty {
                self.lastActivity = Date()
                self.flow.writeDatagrams([(data, endpoint)]) { [weak self] writeError in
                    guard let writeError, let self else {
                        return
                    }
                    self.queue.async {
                        self.finish(error: writeError)
                    }
                }
            }
            if error == nil {
                self.receiveFromRemote(connection, endpoint: endpoint)
            }
        }
    }

    private func startIdleTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in
            guard let self, !self.finished else {
                return
            }
            if Self.idleTimeout <= Date().timeIntervalSince(self.lastActivity) {
                self.finish(error: nil)
            }
        }
        idleTimer = timer
        timer.resume()
    }

    private func finish(error: Error?) {
        guard !finished else {
            return
        }
        finished = true
        if let error {
            logger.debug("[SplitTunnelProxy]udp relay closed: \(error.localizedDescription, privacy: .public)")
        }
        idleTimer?.cancel()
        idleTimer = nil
        for connection in connections.values {
            connection.stateUpdateHandler = nil
            connection.cancel()
        }
        connections.removeAll()
        let flowError = error.map(SplitTunnelRelayParameters.flowError)
        flow.closeReadWithError(flowError)
        flow.closeWriteWithError(flowError)
        onFinish?()
        onFinish = nil
    }
}
