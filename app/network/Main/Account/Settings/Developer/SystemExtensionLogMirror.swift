//
//  SystemExtensionLogMirror.swift
//  URnetwork
//
//  Direct-download macOS build only (`DIRECT_DOWNLOAD`). The packet tunnel
//  SYSTEM extension runs as root and logs to /Library/Logs/URnetwork/extension
//  (DiagnosticsLogContract.systemExtensionLogRoot), not to the App Group
//  container the App Store build shares. The SDK's inventory and exporter
//  only read the ONE root this process recorded with SetLogDirForProcess, so
//  before either runs the app mirrors the sysext's directory into
//  `<its own root>/extension`. The bundle then looks exactly like the App
//  Store build's, source label included.
//

#if os(macOS) && DIRECT_DOWNLOAD

import Foundation
import URnetworkSdk

enum SystemExtensionLogMirror {

    /// Why the sysext's logs are not in the export, or nil when they are.
    private(set) static var unavailableReason: String?

    /// `<app log root>/extension`, or nil when this process has no log root
    /// (configure never ran, or the SDK fell back to its own directory).
    static var destinationDirectory: URL? {
        let root = SdkGetLogRoot()
        guard !root.isEmpty else { return nil }
        return URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent(DiagnosticsLogContract.extensionProcessName, isDirectory: true)
    }

    /// Copies new/changed files and drops vanished ones. Safe to call before
    /// every inventory and export; a mirror that cannot run records why.
    ///
    /// TODO(hardware): verify on a notarized build that the App Sandbox lets
    /// this process read /Library/Logs/URnetwork/extension (0755 dir, 0644
    /// files written by root). If it does not, the sysext must instead hand
    /// its log bytes over the tunnel rpc, and this mirror becomes the reader
    /// of that channel.
    @discardableResult
    static func sync(
        source: URL = DiagnosticsLogContract.systemExtensionProcessLogDirectory,
        destination: URL? = destinationDirectory
    ) -> DiagnosticsLogContract.LogMirrorPlan {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory) && isDirectory.boolValue
        let readable = exists && fileManager.isReadableFile(atPath: source.path)
        unavailableReason = DiagnosticsLogContract.systemExtensionLogsUnavailableReason(
            directoryExists: exists, readable: readable
        )
        guard unavailableReason == nil, let destination else { return .empty }

        try? fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        let plan = DiagnosticsLogContract.logMirrorPlan(
            source: stamps(in: source),
            destination: stamps(in: destination)
        )
        for name in plan.remove {
            try? fileManager.removeItem(at: destination.appendingPathComponent(name))
        }
        for name in plan.copy {
            let target = destination.appendingPathComponent(name)
            try? fileManager.removeItem(at: target)
            do {
                try fileManager.copyItem(at: source.appendingPathComponent(name), to: target)
            } catch {
                unavailableReason = DiagnosticsLogContract.systemExtensionLogsUnavailableReason(
                    directoryExists: true, readable: false
                )
            }
        }
        return plan
    }

    /// Regular files only: glog keeps a `<program>.<SEVERITY>` symlink beside
    /// each real file, and the SDK's inventory skips those too.
    static func stamps(in directory: URL) -> [DiagnosticsLogContract.LogFileStamp] {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names.compactMap { name in
            let path = directory.appendingPathComponent(name).path
            guard let attributes = try? fileManager.attributesOfItem(atPath: path),
                  (attributes[.type] as? FileAttributeType) == .typeRegular else { return nil }
            return DiagnosticsLogContract.LogFileStamp(
                name: name,
                byteCount: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
                modifiedAt: (attributes[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
            )
        }
    }
}

#endif
