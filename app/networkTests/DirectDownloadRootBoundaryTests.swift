//
//  DirectDownloadRootBoundaryTests.swift
//  networkTests
//
//  The direct-download macOS build runs its tunnel as a SYSTEM extension,
//  i.e. as root. It must not depend on the user's keychain or the user's App
//  Group container, so (1) the tunnel intent rides in providerConfiguration
//  and (2) the sysext logs to /Library/Logs/URnetwork, which the app mirrors
//  into its own log root before an export. These pin the pure decisions on
//  both sides (TunnelIntentStore and DiagnosticsLogContract, which the app
//  and both extension targets compile).
//

import Testing
import Foundation
@testable import URnetwork

struct DirectDownloadRootBoundaryTests {

    // MARK: tunnel intent via providerConfiguration

    private static func jwt(_ claims: [String: Any]) -> String {
        let payload = try! JSONSerialization.data(withJSONObject: claims)
        let b64 = payload.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "eyJhbGciOiJub25lIn0.\(b64).sig"
    }

    private static let clientId = "1b4e28ba-2fa1-11d2-883f-0016d3cca427"
    private static let instanceId = "6ba7b810-9dad-11d1-80b4-00c04fd430c8"

    private static var configuration: [String: Any] {
        [
            "by_jwt": jwt(["client_id": clientId, "network_id": "2b4e28ba-2fa1-11d2-883f-0016d3cca427"]),
            "instance_id": instanceId,
            "network_space": #"{"key":{"host_name":"ur.io","env_name":"main"}}"#,
            "rpc_server_pem": "pem",
            "rpc_client_pem": "pem",
            "rpc_listen_hostport": "127.0.0.1:1",
        ]
    }

    @Test func theProfileCarriesAFreshConnectIntentOwnedByTheConfiguredClient() throws {
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        var configuration = Self.configuration
        let entry = try #require(TunnelIntentStore.providerConfigurationEntry(for: configuration, at: at))
        configuration[TunnelIntentStore.providerConfigurationKey] = entry

        let intent = try #require(try TunnelIntentStore.load(fromProviderConfiguration: configuration))
        #expect(intent.connect)
        #expect(intent.source == TunnelIntentStore.sourceApp)
        #expect(intent.changedAt == at)
        // scoped to the same client the rest of the configuration names, so
        // the extension's owner check accepts it
        let owner = try #require(TunnelIntentOwner.fromProviderConfiguration(configuration))
        #expect(intent.applies(to: owner))
        #expect(intent.owner == owner)
    }

    @Test func noEntryIsWrittenWhenTheConfigurationDoesNotIdentifyAClient() {
        var configuration = Self.configuration
        configuration["by_jwt"] = "not-a-jwt"
        #expect(TunnelIntentStore.providerConfigurationEntry(for: configuration) == nil)
    }

    @Test func anAbsentEntryReadsAsNoIntentNotAsAnError() throws {
        #expect(try TunnelIntentStore.load(fromProviderConfiguration: Self.configuration) == nil)
    }

    @Test func aMalformedEntryFailsClosed() {
        for bad in ["{not json", 42, Data([0x00])] as [Any] {
            var configuration = Self.configuration
            configuration[TunnelIntentStore.providerConfigurationKey] = bad
            #expect(throws: TunnelIntentStorageError.self) {
                try TunnelIntentStore.load(fromProviderConfiguration: configuration)
            }
        }
    }

    @Test func theKeyDoesNotCollideWithTheExistingConfigurationKeys() {
        #expect(Self.configuration[TunnelIntentStore.providerConfigurationKey] == nil)
        #expect(TunnelIntentStore.providerConfigurationKey == "tunnel_intent")
    }

    // MARK: system extension log layout

    @Test func theSystemExtensionLogsUnderLibraryLogsWithWorldReadableModes() {
        #expect(DiagnosticsLogContract.systemExtensionLogRoot.path == "/Library/Logs/URnetwork")
        #expect(DiagnosticsLogContract.systemExtensionProcessLogDirectory.path == "/Library/Logs/URnetwork/extension")
        // the same process label the App Store build uses, so a bundle from
        // either build reads the same
        #expect(DiagnosticsLogContract.systemExtensionProcessLogDirectory.lastPathComponent
                == DiagnosticsLogContract.extensionProcessName)
        #expect(DiagnosticsLogContract.systemExtensionDirectoryPermissions == 0o755)
        #expect(DiagnosticsLogContract.systemExtensionFilePermissions == 0o644)
        // glog opens files 0666; this umask is what makes them 0644
        #expect(0o666 & ~DiagnosticsLogContract.systemExtensionUmask == DiagnosticsLogContract.systemExtensionFilePermissions)
    }

    private typealias Stamp = DiagnosticsLogContract.LogFileStamp
    private static func stamp(_ name: String, _ bytes: Int64 = 10, _ t: TimeInterval = 1) -> Stamp {
        Stamp(name: name, byteCount: bytes, modifiedAt: Date(timeIntervalSince1970: t))
    }

    @Test func mirrorCopiesNewAndChangedFilesAndRemovesVanishedOnes() {
        let plan = DiagnosticsLogContract.logMirrorPlan(
            source: [Self.stamp("a.INFO.1"), Self.stamp("b.INFO.2", 20, 5), Self.stamp("c.INFO.3")],
            destination: [Self.stamp("a.INFO.1"), Self.stamp("b.INFO.2", 10, 1), Self.stamp("old.INFO.0")]
        )
        #expect(plan.copy == ["b.INFO.2", "c.INFO.3"])
        #expect(plan.remove == ["old.INFO.0"])
    }

    @Test func mirrorOfAnIdenticalDirectoryIsANoOp() {
        let files = [Self.stamp("a"), Self.stamp("b", 3, 9)]
        #expect(DiagnosticsLogContract.logMirrorPlan(source: files, destination: files) == .empty)
    }

    @Test func mirrorIntoAnEmptyDirectoryCopiesEverythingInStableOrder() {
        let plan = DiagnosticsLogContract.logMirrorPlan(
            source: [Self.stamp("z"), Self.stamp("a")], destination: []
        )
        #expect(plan == DiagnosticsLogContract.LogMirrorPlan(copy: ["a", "z"], remove: []))
    }

    @Test func mirrorFromAnEmptySourceClearsTheDestination() {
        let plan = DiagnosticsLogContract.logMirrorPlan(
            source: [], destination: [Self.stamp("a"), Self.stamp("b")]
        )
        #expect(plan == DiagnosticsLogContract.LogMirrorPlan(copy: [], remove: ["a", "b"]))
    }

    @Test func aChangedModificationTimeAloneTriggersACopy() {
        // a rotated file can be rewritten to the same size
        let plan = DiagnosticsLogContract.logMirrorPlan(
            source: [Self.stamp("a", 10, 2)], destination: [Self.stamp("a", 10, 1)]
        )
        #expect(plan.copy == ["a"])
    }

    @Test func unavailableReasonsArePathFree() {
        let missing = DiagnosticsLogContract.systemExtensionLogsUnavailableReason(directoryExists: false, readable: false)
        let unreadable = DiagnosticsLogContract.systemExtensionLogsUnavailableReason(directoryExists: true, readable: false)
        #expect(missing != nil)
        #expect(unreadable != nil)
        #expect(missing != unreadable)
        for reason in [missing!, unreadable!] {
            #expect(!reason.contains("/Library"))
        }
        #expect(DiagnosticsLogContract.systemExtensionLogsUnavailableReason(directoryExists: true, readable: true) == nil)
    }
}
