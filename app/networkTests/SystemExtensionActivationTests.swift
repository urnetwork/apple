//
//  SystemExtensionActivationTests.swift
//  networkTests
//
//  The direct-download macOS build installs its tunnel as a system
//  extension. These pin the pure half of that flow
//  (network/Shared/SystemExtension/SystemExtensionActivation.swift): where
//  the app must live for a request to be worth submitting, how the
//  OSSystemExtensionRequest delegate callbacks move the state, when a new
//  request is submitted, and which states prompt the user with what.
//

import Testing
import Foundation
@testable import URnetwork

struct SystemExtensionActivationTests {

    // MARK: install location

    @Test func anAppUnderApplicationsCanActivate() {
        let location = SystemExtensionInstallLocation.classify(bundlePath: "/Applications/URnetwork.app")
        #expect(location == .applications)
        #expect(location.canActivate)
    }

    @Test func anAppRunFromTheMountedDiskImageCannot() {
        let location = SystemExtensionInstallLocation.classify(bundlePath: "/Volumes/URnetwork/URnetwork.app")
        #expect(location == .diskImage)
        #expect(!location.canActivate)
    }

    @Test func anAppInDownloadsOrAUserApplicationsFolderCannot() {
        // macOS requires /Applications itself for system extensions; a
        // per-user ~/Applications is rejected with unsupportedParentBundleLocation
        #expect(SystemExtensionInstallLocation.classify(bundlePath: "/Users/me/Downloads/URnetwork.app") == .elsewhere)
        #expect(SystemExtensionInstallLocation.classify(bundlePath: "/Users/me/Applications/URnetwork.app") == .elsewhere)
        // a prefix match on the name is not the folder
        #expect(SystemExtensionInstallLocation.classify(bundlePath: "/ApplicationsBackup/URnetwork.app") == .elsewhere)
    }

    @Test func unnormalizedPathsAreClassifiedByTheirStandardForm() {
        #expect(SystemExtensionInstallLocation.classify(bundlePath: "/Applications/../Applications/URnetwork.app") == .applications)
        #expect(SystemExtensionInstallLocation.classify(bundlePath: "/Volumes/URnetwork/../../Applications/URnetwork.app") == .applications)
    }

    @Test func moveDestinationKeepsTheBundleNameUnderApplications() {
        #expect(SystemExtensionInstallLocation.moveDestination(bundlePath: "/Volumes/URnetwork 1.2/URnetwork.app")
                == "/Applications/URnetwork.app")
    }

    // MARK: reducer

    typealias State = SystemExtensionActivationState
    typealias Event = SystemExtensionActivationEvent
    let reduce = SystemExtensionActivation.reduce

    @Test func requestingFromApplicationsStartsARequest() {
        #expect(reduce(.idle, .activationRequested(.applications)) == .requesting)
    }

    @Test func requestingFromElsewhereDoesNotSubmitAndExplains() {
        let state = reduce(.idle, .activationRequested(.diskImage))
        #expect(state == .notInApplications(.diskImage))
        #expect(state.needsUserAction)
        #expect(state.needsMoveToApplications)
    }

    @Test func approvalThenFinishActivates() {
        var state = reduce(.idle, .activationRequested(.applications))
        state = reduce(state, .needsUserApproval)
        #expect(state == .needsApproval)
        #expect(state.needsUserAction)
        #expect(!state.needsMoveToApplications)
        state = reduce(state, .finished(willCompleteAfterReboot: false))
        #expect(state == .activated(willCompleteAfterReboot: false))
        #expect(state.isActivated)
        #expect(!state.needsUserAction)
    }

    @Test func replacingAnOlderExtensionStaysInFlightAndCanFinishAfterReboot() {
        var state = reduce(.requesting, .replacing(existingVersion: "1.0.0", candidateVersion: "1.1.0"))
        #expect(state == .requesting)
        state = reduce(state, .finished(willCompleteAfterReboot: true))
        #expect(state == .activated(willCompleteAfterReboot: true))
    }

    @Test func aReCheckOfAnActiveExtensionDoesNotFlashRequesting() {
        let active = State.activated(willCompleteAfterReboot: false)
        #expect(reduce(active, .activationRequested(.applications)) == active)
        #expect(reduce(active, .replacing(existingVersion: "1.0", candidateVersion: "1.0")) == active)
        // but a re-check from a bundle that has since been moved out is reported
        #expect(reduce(active, .activationRequested(.elsewhere)) == .notInApplications(.elsewhere))
    }

    @Test func aFailureIsReportedAndTheBundleLocationFailureAsksForAMove() {
        let moved = reduce(.requesting, .failed(.unsupportedParentBundleLocation))
        #expect(moved == .failed(.unsupportedParentBundleLocation))
        #expect(moved.needsUserAction)
        #expect(moved.needsMoveToApplications)

        let policy = reduce(.requesting, .failed(.forbiddenBySystemPolicy))
        #expect(policy == .failed(.forbiddenBySystemPolicy))
        #expect(!policy.needsUserAction)
        #expect(!policy.needsMoveToApplications)
    }

    @Test func aRequestIsNotDuplicatedWhileOneIsPending() {
        #expect(!SystemExtensionActivation.shouldSubmit(from: .requesting))
        #expect(!SystemExtensionActivation.shouldSubmit(from: .needsApproval))
        #expect(SystemExtensionActivation.shouldSubmit(from: .idle))
        #expect(SystemExtensionActivation.shouldSubmit(from: .failed(.requestCanceled)))
        #expect(SystemExtensionActivation.shouldSubmit(from: .notInApplications(.diskImage)))
        // activation is idempotent, and re-submitting is what repairs an
        // extension removed in System Settings
        #expect(SystemExtensionActivation.shouldSubmit(from: .activated(willCompleteAfterReboot: false)))
    }

    @Test func anInstalledCopyIsAlwaysReplacedByTheBundledOne() {
        #expect(SystemExtensionActivation.replacementDecision(existingVersion: "1.0.0", candidateVersion: "1.1.0") == .replace)
        #expect(SystemExtensionActivation.replacementDecision(existingVersion: "1.1.0", candidateVersion: "1.1.0") == .replace)
        #expect(SystemExtensionActivation.replacementDecision(existingVersion: "2.0.0", candidateVersion: "1.1.0") == .replace)
    }

    /// After the in-app updater (DirectUpdater) swaps the bundle under
    /// /Applications and relaunches, the new app's launch activation meets
    /// the previous release's extension: the delegate replaces it (the
    /// pipeline's calendar versions, not semver), the request stays in
    /// flight through the replacement, and either completion lands in
    /// `activated` -- a reboot-deferred one included -- without asking the
    /// user for anything.
    @Test func anUpdatedAppReplacesTheInstalledExtensionOnItsFirstLaunch() {
        let previous = "2026.3.23", updated = "2026.4.1"
        #expect(SystemExtensionActivation.replacementDecision(existingVersion: previous, candidateVersion: updated) == .replace)
        #expect(SystemExtensionActivation.shouldSubmit(from: .idle))

        for willCompleteAfterReboot in [false, true] {
            var state = reduce(.idle, .activationRequested(.applications))
            state = reduce(state, .replacing(existingVersion: previous, candidateVersion: updated))
            #expect(state == .requesting)
            #expect(!state.needsUserAction)
            state = reduce(state, .finished(willCompleteAfterReboot: willCompleteAfterReboot))
            #expect(state == .activated(willCompleteAfterReboot: willCompleteAfterReboot))
            #expect(!state.needsUserAction)
        }
    }

    // MARK: copy

    @Test func promptStatesHaveTitleMessageAndAction() {
        let approval = State.needsApproval
        #expect(SystemExtensionActivationCopy.title(for: approval, appName: "URnetwork") == "Allow the URnetwork network extension")
        #expect(SystemExtensionActivationCopy.message(for: approval, appName: "URnetwork")?.contains("System Settings") == true)
        #expect(SystemExtensionActivationCopy.primaryAction(for: approval) == "Open System Settings")

        let dmg = State.notInApplications(.diskImage)
        #expect(SystemExtensionActivationCopy.title(for: dmg, appName: "URnetwork") == "Move URnetwork to Applications")
        #expect(SystemExtensionActivationCopy.message(for: dmg, appName: "URnetwork")?.contains("disk image") == true)
        #expect(SystemExtensionActivationCopy.primaryAction(for: dmg) == "Move to Applications")

        let rejected = State.failed(.unsupportedParentBundleLocation)
        #expect(SystemExtensionActivationCopy.primaryAction(for: rejected) == "Move to Applications")
    }

    @Test func quietStatesHaveNoCopy() {
        for state in [State.idle, .requesting, .activated(willCompleteAfterReboot: true)] {
            #expect(SystemExtensionActivationCopy.title(for: state, appName: "URnetwork") == nil)
            #expect(SystemExtensionActivationCopy.message(for: state, appName: "URnetwork") == nil)
            #expect(SystemExtensionActivationCopy.primaryAction(for: state) == nil)
        }
    }

    @Test func anUnknownFailureShowsTheSystemsOwnDescription() {
        let state = State.failed(.other(code: 42, description: "something the OS said"))
        #expect(SystemExtensionActivationCopy.message(for: state, appName: "URnetwork") == "something the OS said")
        #expect(SystemExtensionActivationCopy.primaryAction(for: state) == nil)
    }
}
