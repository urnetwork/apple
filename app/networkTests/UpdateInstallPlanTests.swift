//
//  UpdateInstallPlanTests.swift
//  networkTests
//
//  The direct-download macOS build installs an update by the pure
//  UpdateInstallPlan (network/Shared/Updater/UpdateInstallPlan.swift): the
//  paths under the temporary directory, the ditto invocation, the digest
//  comparison, what the unpacked archive must contain, the code signature
//  the unpacked app must carry, and how the installed bundle is replaced
//  (or, off /Applications, not).
//

import Testing
import Foundation
@testable import URnetwork

struct UpdateInstallPlanTests {

    static let offer = UpdateOffer(
        version: ReleaseVersion(base: "2026.4.1", code: 895076000),
        tag: "v2026.4.1-895076000",
        assetName: "URnetwork-2026.4.1-895076000-macos.zip",
        assetURL: URL(string: "https://github.com/urnetwork/build/releases/download/v2026.4.1-895076000/URnetwork-2026.4.1-895076000-macos.zip")!,
        digestHex: String(repeating: "2b", count: 32)
    )
    static let temporary = URL(fileURLWithPath: "/private/var/folders/xx/T", isDirectory: true)
    let plan = UpdateInstallPlan(offer: offer, temporaryDirectory: temporary)

    // MARK: paths

    @Test func theWorkLivesInAPerTagDirectoryUnderTheTemporaryDirectory() {
        #expect(plan.workDirectory.path == "/private/var/folders/xx/T/updates/v2026.4.1-895076000")
        #expect(plan.archiveURL.path == "/private/var/folders/xx/T/updates/v2026.4.1-895076000/URnetwork-2026.4.1-895076000-macos.zip")
        #expect(plan.unpackDirectory.path == "/private/var/folders/xx/T/updates/v2026.4.1-895076000/unpacked")
        #expect(plan.unpackedBundleURL.path == "/private/var/folders/xx/T/updates/v2026.4.1-895076000/unpacked/URnetwork.app")
    }

    @Test func theArchiveIsUnpackedByTheSystemDittoInZipMode() {
        #expect(UpdateInstallPlan.dittoPath == "/usr/bin/ditto")
        #expect(plan.dittoArguments == ["-x", "-k", plan.archiveURL.path, plan.unpackDirectory.path])
    }

    // MARK: digest

    @Test func theDigestComparisonFoldsCaseAndRefusesEmpty() {
        let hex = String(repeating: "2b", count: 32)
        #expect(UpdateInstallPlan.digestMatches(actualHex: hex, expectedHex: hex))
        #expect(UpdateInstallPlan.digestMatches(actualHex: hex.uppercased(), expectedHex: hex))
        #expect(!UpdateInstallPlan.digestMatches(actualHex: String(repeating: "2c", count: 32), expectedHex: hex))
        #expect(!UpdateInstallPlan.digestMatches(actualHex: "", expectedHex: hex))
        #expect(!UpdateInstallPlan.digestMatches(actualHex: hex, expectedHex: ""))
        #expect(!UpdateInstallPlan.digestMatches(actualHex: "", expectedHex: ""))
    }

    // MARK: the unpacked archive

    @Test func theArchiveMustUnpackToExactlyTheAppBundle() {
        #expect(UpdateInstallPlan.bundleName == "URnetwork.app")
        #expect(UpdateInstallPlan.unpackedBundle(topLevelEntries: ["URnetwork.app"]) == "URnetwork.app")
        // ditto's resource-fork sidecar is tolerated; a second bundle, a
        // renamed bundle or nothing at all is not the update
        #expect(UpdateInstallPlan.unpackedBundle(topLevelEntries: ["__MACOSX", "URnetwork.app"]) == "URnetwork.app")
        #expect(UpdateInstallPlan.unpackedBundle(topLevelEntries: []) == nil)
        #expect(UpdateInstallPlan.unpackedBundle(topLevelEntries: ["URnetwork 2.app"]) == nil)
        #expect(UpdateInstallPlan.unpackedBundle(topLevelEntries: ["URnetwork.app", "Other.app"]) == nil)
        #expect(UpdateInstallPlan.unpackedBundle(topLevelEntries: ["URnetwork.app.old-1"]) == nil)
    }

    // MARK: signature

    @Test func theSignatureRequirementNamesTheTeamAndTheProduct() {
        #expect(UpdateInstallPlan.requiredTeamIdentifier == "6BGU69Q742")
        #expect(UpdateInstallPlan.requiredBundleIdentifier == "com.bringyour.urnetwork")
        #expect(UpdateInstallPlan.requiredBundleIdentifier == TunnelProviderIdentity.direct.appBundleIdentifier)
        #expect(UpdateInstallPlan.codeRequirement
                == "anchor apple generic and identifier \"com.bringyour.urnetwork\" and certificate leaf[subject.OU] = \"6BGU69Q742\"")
    }

    @Test func onlyThisTeamsSignatureOfThisProductIsAccepted() {
        typealias Identity = UpdateInstallPlan.SignatureIdentity
        #expect(UpdateInstallPlan.acceptsSignature(Identity(bundleIdentifier: "com.bringyour.urnetwork", teamIdentifier: "6BGU69Q742")))
        // the App Store product is signed by the same team but is not this product
        #expect(!UpdateInstallPlan.acceptsSignature(Identity(bundleIdentifier: "network.ur", teamIdentifier: "6BGU69Q742")))
        #expect(!UpdateInstallPlan.acceptsSignature(Identity(bundleIdentifier: "com.bringyour.urnetwork", teamIdentifier: "DWD39RZH9Z")))
        #expect(!UpdateInstallPlan.acceptsSignature(Identity(bundleIdentifier: "com.bringyour.urnetwork", teamIdentifier: nil)))
        #expect(!UpdateInstallPlan.acceptsSignature(Identity(bundleIdentifier: nil, teamIdentifier: "6BGU69Q742")))
        #expect(!UpdateInstallPlan.acceptsSignature(Identity(bundleIdentifier: "com.bringyour.urnetwork.extension", teamIdentifier: "6BGU69Q742")))
    }

    // MARK: replacement

    @Test func anAppUnderApplicationsIsReplacedInPlace() {
        let strategy = UpdateInstallPlan.strategy(runningBundlePath: "/Applications/URnetwork.app", runningCode: 895075980)
        #expect(strategy == .replaceInPlace(
            installedBundleURL: URL(fileURLWithPath: "/Applications/URnetwork.app"),
            asideURL: URL(fileURLWithPath: "/Applications/URnetwork.app.old-895075980")
        ))
        // an unnormalized path to the same place
        #expect(UpdateInstallPlan.strategy(runningBundlePath: "/Applications/../Applications/URnetwork.app", runningCode: 1)
                == .replaceInPlace(
                    installedBundleURL: URL(fileURLWithPath: "/Applications/URnetwork.app"),
                    asideURL: URL(fileURLWithPath: "/Applications/URnetwork.app.old-1")
                ))
    }

    @Test func anAppRunningAnywhereElseGetsTheDownloadRevealed() {
        for path in ["/Volumes/URnetwork/URnetwork.app", "/Users/me/Downloads/URnetwork.app",
                     "/Users/me/Applications/URnetwork.app", "/ApplicationsBackup/URnetwork.app"] {
            #expect(UpdateInstallPlan.strategy(runningBundlePath: path, runningCode: 895075980) == .revealDownload, Comment(rawValue: path))
        }
    }

    @Test func asideCopiesAreNamedAndRecognizedByOneGrammar() {
        #expect(UpdateInstallPlan.asideName(bundleName: "URnetwork.app", code: 895075980) == "URnetwork.app.old-895075980")
        #expect(UpdateInstallPlan.isStaleAsideName(UpdateInstallPlan.asideName(bundleName: "URnetwork.app", code: 895075980)))
        #expect(UpdateInstallPlan.isStaleAsideName("URnetwork.app.old-0"))
        // this gates a delete under /Applications: a close match is data loss
        for name in ["URnetwork.app", "URnetwork.app.old", "URnetwork.app.old-", "URnetwork.app.old-backup",
                     "URnetwork.app.old-12x", "URnetwork.app.old-12.app", "Other.app.old-12", "URnetwork 2.app.old-12",
                     ".URnetwork.app.old-12", "URnetwork.app.old-１２"] {
            #expect(!UpdateInstallPlan.isStaleAsideName(name), Comment(rawValue: name))
        }
    }

    @Test func theGrantedFolderMustBeTheApplicationsFolderItself() {
        #expect(UpdateInstallPlan.applicationsDirectory == "/Applications")
        #expect(UpdateInstallPlan.isApplicationsFolder("/Applications"))
        #expect(UpdateInstallPlan.isApplicationsFolder("/Applications/"))
        #expect(UpdateInstallPlan.isApplicationsFolder("/Applications/../Applications"))
        #expect(!UpdateInstallPlan.isApplicationsFolder("/Applications/Utilities"))
        #expect(!UpdateInstallPlan.isApplicationsFolder("/Users/me/Applications"))
        #expect(!UpdateInstallPlan.isApplicationsFolder("/"))
    }
}
