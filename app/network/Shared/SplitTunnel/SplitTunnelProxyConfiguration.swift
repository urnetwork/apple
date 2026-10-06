//
//  SplitTunnelProxyConfiguration.swift
//  URnetwork
//
//  What the app tells the split tunnel system extension: the signing
//  identifiers of the excluded apps. The same value travels two ways. It is
//  stored in the NETransparentProxyManager's
//  NETunnelProviderProtocol.providerConfiguration, which is what the
//  extension reads when the proxy starts (the system extension runs as root
//  and never reads the user's app group), and it is sent as a provider
//  message when the list changes while the proxy runs, so a change applies
//  without restarting it.
//
//  The list is normalized on the way in and on the way out, so two lists
//  that mean the same thing compare equal and the app never rewrites the
//  system's VPN preferences for a reordering.
//
//  Pure Foundation: compiled into the app, the extension targets and the
//  unit tests.
//

import Foundation

/// The excluded apps as the extension receives them (see the file comment).
struct SplitTunnelProxyConfiguration: Equatable {

    // the providerConfiguration layout and its keys
    static let version = 1
    static let versionKey = "version"
    static let excludedAppsKey = "excluded_apps"

    /// More is not a list a person picked from /Applications.
    static let maximumExcludedApps = 256
    /// A code signing identifier is a short reverse-DNS string.
    static let maximumIdentifierLength = 255

    /// Lowercase-insensitive unique, sorted signing identifiers.
    let excludedApps: [String]

    /// Takes any list and normalizes it.
    init(excludedApps: [String]) {
        self.excludedApps = Self.normalize(excludedApps)
    }

    /// The configuration that excludes no app.
    static let empty = SplitTunnelProxyConfiguration(excludedApps: [])

    /// No app is excluded.
    var isEmpty: Bool {
        excludedApps.isEmpty
    }

    /// Trimmed, valid, unique (ignoring case, first spelling kept), sorted
    /// ignoring case, and bounded.
    static func normalize(_ apps: [String]) -> [String] {
        var seen = Set<String>()
        var normalized: [String] = []
        for app in apps {
            let identifier = app.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isValidIdentifier(identifier) else {
                continue
            }
            if seen.insert(identifier.lowercased()).inserted {
                normalized.append(identifier)
            }
        }
        normalized.sort {
            let order = $0.caseInsensitiveCompare($1)
            return order == .orderedSame ? $0 < $1 : order == .orderedAscending
        }
        return Array(normalized.prefix(maximumExcludedApps))
    }

    /// Letters, digits, '.', '-' and '_', with no empty label: the shape of a
    /// bundle or signing identifier. Anything else is not something the
    /// picker produced and is dropped rather than matched.
    static func isValidIdentifier(_ identifier: String) -> Bool {
        guard !identifier.isEmpty, identifier.count <= maximumIdentifierLength else {
            return false
        }
        guard identifier.unicodeScalars.allSatisfy({ scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "-" || scalar == "_")
        }) else {
            return false
        }
        return !identifier.split(separator: ".", omittingEmptySubsequences: false).contains(where: { $0.isEmpty })
    }

    // MARK: providerConfiguration

    /// The NETunnelProviderProtocol.providerConfiguration value.
    var providerConfiguration: [String: Any] {
        [
            Self.versionKey: Self.version,
            Self.excludedAppsKey: excludedApps,
        ]
    }

    /// nil when the dictionary does not carry a list (a profile this build
    /// did not write); entries that are not strings are dropped.
    init?(providerConfiguration: [String: Any]?) {
        guard let apps = providerConfiguration?[Self.excludedAppsKey] as? [Any] else {
            return nil
        }
        self.init(excludedApps: apps.compactMap { $0 as? String })
    }

    // MARK: provider message

    /// The provider message: providerConfiguration as JSON.
    var messageData: Data {
        // a dictionary of a version and strings always serializes
        (try? JSONSerialization.data(withJSONObject: providerConfiguration, options: [.sortedKeys])) ?? Data()
    }

    /// nil when the message is not a JSON object carrying a list.
    init?(messageData: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: messageData),
              let dictionary = object as? [String: Any] else {
            return nil
        }
        self.init(providerConfiguration: dictionary)
    }
}
