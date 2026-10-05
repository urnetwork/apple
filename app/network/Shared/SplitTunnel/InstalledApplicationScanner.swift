//
//  InstalledApplicationScanner.swift
//  URnetwork
//
//  macOS only: finds the app bundles the split tunnel picker offers. Walks
//  /Applications (and the folders directly in it, where suites such as
//  "Microsoft Office" keep their apps, without descending into bundles),
//  reads each Info.plist and the code signing identifier, and hands them to
//  InstalledApplicationCatalog. Read-only: the sandbox allows reading
//  /Applications, and nothing found here leaves the Mac.
//

#if os(macOS)

import AppKit
import Foundation
import Security

/// Reads /Applications for the picker (see the file comment).
enum InstalledApplicationScanner {

    static let applicationsDirectory = URL(fileURLWithPath: "/Applications", isDirectory: true)

    /// The catalog without this app and its own extensions. Slow (a code
    /// signature read per bundle): call it off the main thread.
    static func scan() -> [InstalledApplication] {
        var applications: [InstalledApplication] = []
        for url in bundleURLs(in: applicationsDirectory, depth: 2) {
            guard let info = Bundle(url: url)?.infoDictionary else {
                continue
            }
            if let application = InstalledApplicationCatalog.application(
                infoDictionary: info,
                signingIdentifier: signingIdentifier(of: url),
                path: url.path
            ) {
                applications.append(application)
            }
        }
        let family = TunnelProviderIdentity.flavor
        return InstalledApplicationCatalog.catalog(applications, excluding: [
            Bundle.main.bundleIdentifier ?? family.appBundleIdentifier,
            family.appBundleIdentifier,
            family.tunnelBundleIdentifier,
            family.splitTunnelBundleIdentifier,
        ])
    }

    /// The app's icon as Finder shows it.
    static func icon(for application: InstalledApplication) -> NSImage {
        NSWorkspace.shared.icon(forFile: application.path)
    }

    /// The app bundles in `directory` and in its folders, `depth` levels
    /// deep in all; a bundle is never entered.
    private static func bundleURLs(in directory: URL, depth: Int) -> [URL] {
        guard 0 < depth,
              let entries = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
              ) else {
            return []
        }
        var urls: [URL] = []
        for entry in entries {
            if entry.pathExtension == "app" {
                urls.append(entry)
            } else if (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                urls.append(contentsOf: bundleURLs(in: entry, depth: depth - 1))
            }
        }
        return urls
    }

    /// The identifier the split tunnel matches (NEFlowMetaData's
    /// sourceAppSigningIdentifier comes from the same signature); nil for an
    /// unsigned bundle or one whose signature cannot be read.
    private static func signingIdentifier(of url: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else {
            return nil
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dictionary = information as? [String: Any] else {
            return nil
        }
        return dictionary[kSecCodeInfoIdentifier as String] as? String
    }
}

#endif
