//
//  DiagnosticsLogLocationTests.swift
//  networkTests
//
//  Covers where each process writes its logs. The app and the extension are
//  separate processes with separate containers; only an App Group lets the app
//  read what the extension wrote. When the container is unavailable -- a build
//  whose provisioning profile predates the group -- each process must fall
//  back to its own directory rather than failing, so an export still produces
//  the logs it can reach.
//
//  These test DiagnosticsLogContract, the file the extension target compiles
//  too, so the layout they pin is the one BOTH processes use rather than only
//  the app's copy of it.
//

import Testing
import Foundation
@testable import URnetwork

struct DiagnosticsLogLocationTests {

    @Test func fallsBackToALocalRootWhenTheContainerIsUnavailable() {
        let location = DiagnosticsLogContract.logRoot(
            containerURL: nil,
            fallbackURL: URL(fileURLWithPath: "/tmp/urnetwork-test")
        )
        #expect(location.isShared == false)
        #expect(location.url.path == "/tmp/urnetwork-test/Logs")
    }

    @Test func usesTheSharedContainerWhenAvailable() {
        let location = DiagnosticsLogContract.logRoot(
            containerURL: URL(fileURLWithPath: "/private/group/network.ur"),
            fallbackURL: URL(fileURLWithPath: "/tmp/urnetwork-test")
        )
        #expect(location.isShared == true)
        #expect(location.url.path == "/private/group/network.ur/Logs")
    }

    @Test func processNamesAreDistinctSoRetentionDoesNotCollide() {
        // both processes read these from the contract, so this is now the
        // cross-process property and not just the app's half of it:
        // clearOldLogs prunes the directory it is handed, so a shared
        // subdirectory name would have each process deleting the other's
        // history.
        //
        // The extension's own wrapper cannot be reached from this target (it
        // imports URnetworkExtensionSdk, a second copy of the same Go
        // framework), but it no longer has a copy of these names to drift
        // from: it compiles this very file, and reads processName from it.
        #expect(DiagnosticsLogContract.appProcessName != DiagnosticsLogContract.extensionProcessName)
        #expect(DiagnosticsLogLocation.appProcessName == DiagnosticsLogContract.appProcessName)
        #expect(DiagnosticsLogLocation.extensionProcessName
                == DiagnosticsLogContract.extensionProcessName)
    }

    /// The entitlement resolving is not the same thing as glog landing in the
    /// shared root: SetLogDirForProcess silently falls back to a process-local
    /// directory of its own when it cannot create or open <root>/<process>,
    /// and reports that only by recording a different root. Reported as
    /// available, the app claims the extension's logs are in a bundle that
    /// does not contain them and says nothing about the gap.
    @Test func sharedRootIsOnlyInUseWhenTheSdkRecordedThatSameRoot() {
        let requested = URL(fileURLWithPath: "/private/group/network.ur/Logs")

        #expect(DiagnosticsLogContract.sharedRootIsInUse(
            requestedRoot: requested,
            actualRoot: "/private/group/network.ur/Logs",
            isShared: true,
            setLogDirFailed: false
        ) == true)

        // the sdk's own temp-dir fallback
        #expect(DiagnosticsLogContract.sharedRootIsInUse(
            requestedRoot: requested,
            actualRoot: "/private/var/tmp/urnetwork-logs",
            isShared: true,
            setLogDirFailed: false
        ) == false)

        // nothing recorded at all
        #expect(DiagnosticsLogContract.sharedRootIsInUse(
            requestedRoot: requested,
            actualRoot: "",
            isShared: true,
            setLogDirFailed: false
        ) == false)

        // an error out of SetLogDirForProcess is not discarded
        #expect(DiagnosticsLogContract.sharedRootIsInUse(
            requestedRoot: requested,
            actualRoot: "/private/group/network.ur/Logs",
            isShared: true,
            setLogDirFailed: true
        ) == false)

        // no container in the first place
        #expect(DiagnosticsLogContract.sharedRootIsInUse(
            requestedRoot: requested,
            actualRoot: "/private/group/network.ur/Logs",
            isShared: false,
            setLogDirFailed: false
        ) == false)
    }

    @Test func unavailableReasonsAreDistinctAndCarryNoPaths() {
        let noContainer = DiagnosticsLogLocation.unavailableReason(
            isShared: false, setLogDirFailed: false)
        let openFailed = DiagnosticsLogLocation.unavailableReason(
            isShared: true, setLogDirFailed: true)
        let fellBack = DiagnosticsLogLocation.unavailableReason(
            isShared: true, setLogDirFailed: false)

        #expect(noContainer != openFailed)
        #expect(openFailed != fellBack)
        // these strings are copied verbatim into the bundle's README, which is
        // the one entry the SDK writes without the redaction transform -- a
        // container path here ships the app group's install-stable UUID inside
        // a bundle that redacts that same UUID everywhere else
        for reason in [noContainer, openFailed, fellBack] {
            #expect(!reason.contains("/"))
        }
    }

    /// macOS requires app group identifiers to be team-id prefixed and iOS
    /// requires them bare. With the bare identifier on macOS the container
    /// never resolves, both processes fall back to their own caches
    /// directories, and a macOS bundle can never contain the extension's logs.
    @Test func macOSAppGroupIdentifierIsTeamPrefixed() {
        #expect(DiagnosticsLogContract.appGroupIdentifier(
            grantedGroups: ["ABCDE12345.group.network.ur"],
            teamIdentifier: "ABCDE12345",
            needsTeamPrefix: false
        ) == "group.network.ur")

        // what the signature actually grants wins, so a build signed by
        // another team resolves its own container
        #expect(DiagnosticsLogContract.appGroupIdentifier(
            grantedGroups: ["ZZZZZ99999.group.network.ur"],
            teamIdentifier: "ABCDE12345",
            needsTeamPrefix: true
        ) == "ZZZZZ99999.group.network.ur")

        #expect(DiagnosticsLogContract.appGroupIdentifier(
            grantedGroups: [],
            teamIdentifier: "ABCDE12345",
            needsTeamPrefix: true
        ) == "ABCDE12345.group.network.ur")

        #expect(DiagnosticsLogContract.appGroupIdentifier(
            grantedGroups: [],
            teamIdentifier: nil,
            needsTeamPrefix: true
        ) == "group.network.ur")
    }
}
