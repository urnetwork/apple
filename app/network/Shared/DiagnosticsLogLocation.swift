//
//  DiagnosticsLogLocation.swift
//  URnetwork
//
//  Where the APP process writes its logs, and whether the shared root is
//  really in use.
//
//  The app and the packet tunnel extension are separate processes with
//  separate containers, and the real DeviceLocal runs in the extension. An App
//  Group container is the only way the app can read what the extension wrote,
//  and it is the right way rather than shipping the files over the device rpc:
//  the extension runs on a 20MB device memory target, and log files are up to
//  16MB each.
//
//  The layout itself (group identifier, "Logs/<process>") lives in
//  DiagnosticsLogContract, which the extension target compiles too, so the two
//  processes cannot drift apart.
//

import Foundation
import URnetworkSdk

enum DiagnosticsLogLocation {

    static var appGroupIdentifier: String { DiagnosticsLogContract.appGroupIdentifier }

    static let appProcessName = DiagnosticsLogContract.appProcessName
    static let extensionProcessName = DiagnosticsLogContract.extensionProcessName

    /// Whether this process is really logging into the shared container,
    /// recorded by `configure`.
    ///
    /// Read this from the ui rather than calling `configure` again: configure
    /// re-points glog and must run exactly once per process, at startup.
    private(set) static var isSharedContainerAvailable = false

    /// Why the extension's logs cannot be in an export, or nil when the shared
    /// root is in use and they can be.
    ///
    /// Deliberately path-free: this string is copied verbatim into the
    /// bundle's README "NOT INCLUDED" list, which is the one entry the SDK
    /// writes without the redaction transform, so a container path here would
    /// ship the app group's install-stable UUID inside a bundle that redacts
    /// that same UUID everywhere else.
    private(set) static var sharedRootUnavailableReason: String?

    /// Points this process's glog at its own subdirectory of the log root.
    /// Call once per process, at startup. Returns whether the shared container
    /// is in use.
    @discardableResult
    static func configure(processName: String) -> Bool {
        let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        )
        let fallback = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory

        let location = DiagnosticsLogContract.logRoot(containerURL: container, fallbackURL: fallback)

        try? FileManager.default.createDirectory(at: location.url, withIntermediateDirectories: true)

        var err: NSError?
        SdkSetLogDirForProcess(location.url.path, processName, &err)

        // the sdk falls back to a process-local directory of its own when the
        // root cannot be created or opened, and reports that only by recording
        // a different root -- so read back what it actually chose instead of
        // trusting the entitlement to have been enough
        let inUse = DiagnosticsLogContract.sharedRootIsInUse(
            requestedRoot: location.url,
            actualRoot: SdkGetLogRoot(),
            isShared: location.isShared,
            setLogDirFailed: err != nil
        )

        isSharedContainerAvailable = inUse
        sharedRootUnavailableReason = inUse
            ? nil
            : unavailableReason(isShared: location.isShared, setLogDirFailed: err != nil)
        return inUse
    }

    /// The reason recorded in the bundle when the shared root is not in use.
    static func unavailableReason(isShared: Bool, setLogDirFailed: Bool) -> String {
        if !isShared {
            return "app group container unavailable in this build"
        }
        if setLogDirFailed {
            return "the log directory could not be opened"
        }
        return "logging fell back to a process-local directory outside the app group"
    }
}
