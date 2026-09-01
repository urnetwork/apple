//
//  DiagnosticsLogContract.swift
//  URnetwork
//
//  The app <-> extension log-layout contract: the app group identifier, the
//  "Logs/<processName>" layout underneath it, and the rules for deciding
//  whether the shared root was really reached.
//
//  This file is compiled into BOTH the app target and the packet tunnel
//  extension target (project.pbxproj lists it explicitly in the URnetworkVPN
//  sources phase, the same way extension/TunnelMemoryBounds.swift is listed in
//  the test target's). The two processes previously kept private copies of
//  these constants, so nothing caught them drifting apart -- and a drift here
//  is silent: the app reads one directory and the extension writes another,
//  and the export just looks empty. It carries no SDK import precisely so it
//  can be shared: the app binds URnetworkSdk and the extension binds
//  URnetworkExtensionSdk, two separately named frameworks generated from the
//  same Go package.
//

import Foundation
#if os(macOS)
import Security
#endif

enum DiagnosticsLogContract {

    /// The app group as registered for iOS/iOS-simulator builds.
    ///
    /// macOS requires app group identifiers to be team-id prefixed, so on that
    /// platform this is not the identifier to pass to
    /// `containerURL(forSecurityApplicationGroupIdentifier:)` -- use
    /// `appGroupIdentifier`, which resolves the prefixed form.
    static let appGroupIdentifierBase = "group.network.ur"

    static let logsDirectoryName = "Logs"

    static let appProcessName = "app"
    static let extensionProcessName = "extension"

    /// macOS app groups must be team-id prefixed ("TEAMID.group.network.ur");
    /// iOS app groups must not be. Both platforms are built from the same
    /// sources here (SUPPORTED_PLATFORMS is "iphoneos iphonesimulator macosx"),
    /// so the identifier has to be resolved per platform at runtime rather
    /// than hardcoded.
    #if os(macOS)
    static let appGroupIdentifierNeedsTeamPrefix = true
    #else
    static let appGroupIdentifierNeedsTeamPrefix = false
    #endif

    /// The app group identifier this process should ask the file manager for.
    static var appGroupIdentifier: String {
        appGroupIdentifier(
            grantedGroups: signedApplicationGroups(),
            teamIdentifier: signingTeamIdentifier(),
            needsTeamPrefix: appGroupIdentifierNeedsTeamPrefix
        )
    }

    /// Resolves the identifier from what the running binary was actually
    /// granted, rather than reconstructing it from a hardcoded team id: the
    /// entitlement is the authority, and a build signed by a different team
    /// (a fork, an enterprise re-sign) then still resolves its own container.
    /// The team-prefixed form is the fallback, and the bare form the last
    /// resort -- when neither is right the container simply does not resolve,
    /// which the export reports as a missing source rather than failing.
    static func appGroupIdentifier(
        grantedGroups: [String],
        teamIdentifier: String?,
        needsTeamPrefix: Bool
    ) -> String {
        guard needsTeamPrefix else { return appGroupIdentifierBase }

        if let granted = grantedGroups.first(where: {
            $0 == appGroupIdentifierBase || $0.hasSuffix(".\(appGroupIdentifierBase)")
        }) {
            return granted
        }
        if let teamIdentifier, !teamIdentifier.isEmpty {
            return "\(teamIdentifier).\(appGroupIdentifierBase)"
        }
        return appGroupIdentifierBase
    }

    /// The log root, and whether it is the shared container.
    ///
    /// `isShared == false` means this build cannot see the other process's
    /// logs -- normally a provisioning profile without the App Group. The
    /// export reports that as a missing source rather than failing.
    static func logRoot(containerURL: URL?, fallbackURL: URL) -> (url: URL, isShared: Bool) {
        if let containerURL {
            return (containerURL.appendingPathComponent(logsDirectoryName), true)
        }
        return (fallbackURL.appendingPathComponent(logsDirectoryName), false)
    }

    /// Whether glog really ended up in the shared root we asked for.
    ///
    /// Resolving the App Group entitlement is not the same thing as logging
    /// into it: `SetLogDirForProcess` independently falls back to a
    /// process-local directory under the OS temp dir when it cannot create or
    /// open `<root>/<process>`, and reports that only by recording a
    /// different root. Trusting the entitlement alone leaves the app claiming
    /// the extension's logs are present while the real log root is somewhere
    /// else entirely, and the export then says nothing about the gap.
    static func sharedRootIsInUse(
        requestedRoot: URL,
        actualRoot: String,
        isShared: Bool,
        setLogDirFailed: Bool
    ) -> Bool {
        guard isShared, !setLogDirFailed, !actualRoot.isEmpty else { return false }
        return URL(fileURLWithPath: actualRoot).standardizedFileURL.path
            == requestedRoot.standardizedFileURL.path
    }

    // MARK: - Code signing

    #if os(macOS)

    /// The application groups the running binary's signature actually grants.
    private static func signedApplicationGroups() -> [String] {
        guard let entitlements = signingInformation()?[kSecCodeInfoEntitlementsDict as String]
                as? [String: Any] else {
            return []
        }
        return entitlements["com.apple.security.application-groups"] as? [String] ?? []
    }

    private static func signingTeamIdentifier() -> String? {
        signingInformation()?[kSecCodeInfoTeamIdentifier as String] as? String
    }

    private static func signingInformation() -> [String: Any]? {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(rawValue: 0), &code) == errSecSuccess,
              let code else {
            return nil
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(rawValue: 0), &staticCode) == errSecSuccess,
              let staticCode else {
            return nil
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess else {
            return nil
        }
        return information as? [String: Any]
    }

    #else

    private static func signedApplicationGroups() -> [String] { [] }

    private static func signingTeamIdentifier() -> String? { nil }

    #endif
}
