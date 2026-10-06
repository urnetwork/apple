//
//  InstalledApplicationCatalog.swift
//  URnetwork
//
//  The apps the macOS split tunnel picker offers: the bundles in
//  /Applications, each named by the identifier the split tunnel matches --
//  its code signing identifier, or its bundle identifier when the signature
//  cannot be read (the two are almost always the same string). The
//  filesystem walk and the signature read are in
//  InstalledApplicationScanner.swift (macOS only); turning what they find
//  into the list is here, free of AppKit, so the tests drive it on the iOS
//  simulator.
//

import Foundation

/// An app bundle the picker offers.
struct InstalledApplication: Identifiable, Equatable, Hashable {
    /// what an app rule stores and the extension matches
    let identifier: String
    let bundleIdentifier: String
    let name: String
    let path: String

    var id: String { identifier }
}

/// Turns the bundles the scanner found into the picker's list.
enum InstalledApplicationCatalog {

    /// One app bundle, from its Info.plist and its signing identifier.
    static func application(
        infoDictionary: [String: Any],
        signingIdentifier: String?,
        path: String
    ) -> InstalledApplication? {
        let bundleIdentifier = (infoDictionary["CFBundleIdentifier"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let signing = signingIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let identifier = SplitTunnelProxyConfiguration.isValidIdentifier(signing) ? signing : bundleIdentifier
        guard SplitTunnelProxyConfiguration.isValidIdentifier(identifier) else {
            return nil
        }
        let fileName = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let name = [
            infoDictionary["CFBundleDisplayName"] as? String,
            infoDictionary["CFBundleName"] as? String,
            fileName,
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty } ?? identifier
        return InstalledApplication(
            identifier: identifier,
            bundleIdentifier: bundleIdentifier.isEmpty ? identifier : bundleIdentifier,
            name: name,
            path: path
        )
    }

    /// Unique by identifier (ignoring case, first found kept), without the
    /// apps that must never be excluded -- this app, its extensions -- and
    /// sorted by name the way Finder sorts.
    static func catalog(
        _ applications: [InstalledApplication],
        excluding ownIdentifiers: Set<String>
    ) -> [InstalledApplication] {
        let own = Set(ownIdentifiers.map { $0.lowercased() })
        var seen = Set<String>()
        var catalog: [InstalledApplication] = []
        for application in applications {
            let identifier = application.identifier.lowercased()
            if own.contains(identifier) || own.contains(application.bundleIdentifier.lowercased()) {
                continue
            }
            if seen.insert(identifier).inserted {
                catalog.append(application)
            }
        }
        catalog.sort {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.identifier < $1.identifier : order == .orderedAscending
        }
        return catalog
    }

    /// The apps whose name or identifier contains every word of the query,
    /// ignoring case and diacritics; all of them for an empty query.
    static func search(_ applications: [InstalledApplication], query: String) -> [InstalledApplication] {
        let words = query
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard !words.isEmpty else {
            return applications
        }
        return applications.filter { application in
            words.allSatisfy { word in
                application.name.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                    || application.identifier.range(of: word, options: [.caseInsensitive]) != nil
            }
        }
    }

    /// The installed app an app rule names, matched ignoring case on the
    /// signing or the bundle identifier.
    static func application(
        for identifier: String,
        in applications: [InstalledApplication]
    ) -> InstalledApplication? {
        let wanted = identifier.lowercased()
        return applications.first { $0.identifier.lowercased() == wanted }
            ?? applications.first { $0.bundleIdentifier.lowercased() == wanted }
    }
}
