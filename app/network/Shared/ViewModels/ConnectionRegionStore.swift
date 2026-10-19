//
//  ConnectionRegionStore.swift
//  URnetwork
//

import Foundation
import SwiftUI
import URnetworkSdk

/**
 * The connection region (the ingress country): where the user says they
 * connect from. It picks the DNS the app uses to reach URnetwork's own names
 * (api, connect, extenders): its encrypted resolvers ahead of the defaults,
 * then an unencrypted last resort for URnetwork names only. It never changes
 * the tunnel's DNS (the "Traffic DNS" settings).
 *
 * The network space stores it (local only, never sent to the server) and
 * applies it in place from the next lookup. The login screen control and the
 * DNS settings picker read and write that one value. "" is Other / Undisclosed.
 */

/// What the store reads from and writes to: the active network space, or a
/// fake in tests.
protocol ConnectionRegionSource: AnyObject {
    /// lower-case codes of the regions with a recommendation
    func regionCodes() -> [String]
    func dohUrls(_ code: String) -> [String]
    func plainDnsServers(_ code: String) -> [String]
    func storedCode() -> String
    /// stores `code` and returns the stored value ("" for unknown)
    func store(_ code: String) -> String
}

/// The sdk's regions and a network space's stored region.
final class NetworkSpaceConnectionRegionSource: ConnectionRegionSource {
    let networkSpace: SdkNetworkSpace

    init(_ networkSpace: SdkNetworkSpace) {
        self.networkSpace = networkSpace
    }

    func regionCodes() -> [String] {
        controlDohStrings(SdkIngressCountryCodes())
    }

    func dohUrls(_ code: String) -> [String] {
        controlDohStrings(SdkIngressDohUrls(code))
    }

    func plainDnsServers(_ code: String) -> [String] {
        controlDohStrings(SdkIngressPlainDnsServers(code))
    }

    func storedCode() -> String {
        networkSpace.getIngressCountryCode()
    }

    func store(_ code: String) -> String {
        networkSpace.setIngressCountryCode(code)
    }
}

/// One row of the picker. `code` "" is Other / Undisclosed.
struct ConnectionRegionOption: Identifiable, Equatable {
    let code: String
    let name: String

    var id: String { code }
}

/// The localized name of a region code, from the platform locale.
func connectionRegionName(_ code: String, locale: Locale = .current) -> String {
    if code.isEmpty {
        return String(localized: "Other / Undisclosed")
    }
    return locale.localizedString(forRegionCode: code.uppercased()) ?? code.uppercased()
}

/// The picker rows: Other / Undisclosed first, then exactly the regions with a
/// recommendation, by localized name.
func connectionRegionOptions(_ codes: [String], locale: Locale = .current) -> [ConnectionRegionOption] {
    var seen = Set<String>()
    let regions = codes
        .map { $0.lowercased() }
        .filter { !$0.isEmpty && seen.insert($0).inserted }
        .map { ConnectionRegionOption(code: $0, name: connectionRegionName($0, locale: locale)) }
        .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    return [ConnectionRegionOption(code: "", name: connectionRegionName("", locale: locale))] + regions
}

/// The resolvers a region selects; both empty means the default resolvers.
struct ConnectionRegionResolvers: Equatable {
    let encrypted: [String]
    let plainFallback: [String]

    var usesDefaults: Bool {
        encrypted.isEmpty && plainFallback.isEmpty
    }
}

@MainActor
final class ConnectionRegionStore: ObservableObject {

    @Published private(set) var options: [ConnectionRegionOption] = []
    /// the stored region, "" for Other / Undisclosed
    @Published private(set) var selectedCode: String = ""

    private var source: ConnectionRegionSource?
    private let locale: Locale

    init(locale: Locale = .current) {
        self.locale = locale
    }

    var loaded: Bool {
        source != nil
    }

    /// Reads the regions and the stored value of `source` (re-read every
    /// time: the other control may have changed it).
    func setup(_ source: ConnectionRegionSource?) {
        self.source = source
        reload()
    }

    func setup(_ networkSpace: SdkNetworkSpace?) {
        setup(networkSpace.map { NetworkSpaceConnectionRegionSource($0) })
    }

    func reload() {
        guard let source else {
            options = connectionRegionOptions([], locale: locale)
            selectedCode = ""
            return
        }
        options = connectionRegionOptions(source.regionCodes(), locale: locale)
        selectedCode = source.storedCode()
    }

    var selectedName: String {
        connectionRegionName(selectedCode, locale: locale)
    }

    /// Stores `code` as the region and shows what the space stored.
    func select(_ code: String) {
        guard let source else {
            return
        }
        selectedCode = source.store(code)
    }

    func resolvers(_ code: String) -> ConnectionRegionResolvers {
        guard let source, !code.isEmpty else {
            return ConnectionRegionResolvers(encrypted: [], plainFallback: [])
        }
        return ConnectionRegionResolvers(
            encrypted: source.dohUrls(code),
            plainFallback: source.plainDnsServers(code)
        )
    }
}

// MARK: can't reach URnetwork

/**
 * Whether `error` means the app could not reach URnetwork at all (DNS, dial,
 * TLS, timeout), as opposed to an answer from the platform (an HTTP status,
 * a result error: auth or validation). Only the former suggests choosing a
 * connection region.
 */
func isCantReachUrnetworkError(_ error: Error) -> Bool {
    if error is CancellationError {
        return false
    }
    let nsError = error as NSError
    if nsError.domain == NSURLErrorDomain {
        switch nsError.code {
        case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed,
             NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet,
             NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted,
             NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateHasUnknownRoot,
             NSURLErrorCannotLoadFromNetwork:
            return true
        default:
            return false
        }
    }
    let message = nsError.localizedDescription.lowercased()
    // connect.HttpStatusError renders as "<code> <text>: <body>": the platform answered
    if let first = message.split(separator: " ").first, first.count == 3, Int(first) != nil {
        return false
    }
    let markers = [
        "no such host", "lookup ", "dial tcp", "dial udp", "i/o timeout", "context deadline exceeded",
        "connection refused", "connection reset", "network is unreachable", "no route to host",
        "tls: ", "x509: ", "timeout awaiting response headers", "unexpected eof", ": eof",
    ]
    return markers.contains { message.contains($0) }
}

/**
 * The app-wide "Can't reach URnetwork" prompt. Api calls report their
 * failures; a can't-reach failure raises the prompt, which opens the
 * connection region picker. It never changes the region by itself.
 */
@MainActor
final class CantReachUrnetworkPrompt: ObservableObject {

    static let shared = CantReachUrnetworkPrompt()

    @Published private(set) var visible = false

    /// Raises the prompt for a can't-reach failure; returns whether it did.
    @discardableResult
    func report(_ error: Error) -> Bool {
        guard isCantReachUrnetworkError(error) else {
            return false
        }
        visible = true
        return true
    }

    func dismiss() {
        visible = false
    }
}

/// Reports an api failure to the shared prompt and passes it on (for the
/// sdk callbacks, which may run off the main actor).
func reportUrnetworkReachability(_ error: Error) -> Error {
    if isCantReachUrnetworkError(error) {
        Task { @MainActor in
            CantReachUrnetworkPrompt.shared.report(error)
        }
    }
    return error
}
