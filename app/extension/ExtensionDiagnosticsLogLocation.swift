//
//  ExtensionDiagnosticsLogLocation.swift
//  network (packet tunnel extension)
//
//  Where the extension process writes its logs.
//
//  The layout itself lives in network/Shared/DiagnosticsLogContract.swift,
//  which this target compiles too (listed explicitly in the URnetworkVPN
//  sources phase). Only this thin wrapper is duplicated, because it is the
//  part that has to touch the SDK: the app target binds URnetworkSdk and this
//  target binds URnetworkExtensionSdk -- two separately named xcframeworks
//  generated from the same Go package, so a single Swift file that imports one
//  of them cannot serve both targets.
//

import Foundation
import URnetworkExtensionSdk

enum ExtensionDiagnosticsLogLocation {

    static var appGroupIdentifier: String { DiagnosticsLogContract.appGroupIdentifier }

    static let processName = DiagnosticsLogContract.extensionProcessName

    /// Points this process's glog at its own subdirectory of the shared log
    /// root (or a local fallback when the App Group container is
    /// unreachable). Call once per process, at startup -- before anything that
    /// can fail, since glog writes nothing anywhere until this has run.
    @discardableResult
    static func configure() -> Bool {
        let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        )
        let fallback = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory

        let location = DiagnosticsLogContract.logRoot(containerURL: container, fallbackURL: fallback)

        try? FileManager.default.createDirectory(at: location.url, withIntermediateDirectories: true)

        var err: NSError?
        SdkSetLogDirForProcess(location.url.path, processName, &err)

        // the app decides what an export says about this process from its own
        // side (an empty logs/extension/ is reported as a missing source), so
        // the return here is for the extension's own os_log only
        return DiagnosticsLogContract.sharedRootIsInUse(
            requestedRoot: location.url,
            actualRoot: SdkGetLogRoot(),
            isShared: location.isShared,
            setLogDirFailed: err != nil
        )
    }
}
