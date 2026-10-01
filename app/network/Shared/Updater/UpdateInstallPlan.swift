//
//  UpdateInstallPlan.swift
//  URnetwork
//
//  The pure half of installing a direct-download update: where the download
//  and the unpacked bundle go, what the unpacked app must prove before it
//  may replace the running one, and how the replacement happens. Nothing
//  here touches the file system, the network or the Security framework;
//  DirectUpdater (DIRECT_DOWNLOAD only) executes the plan, and the unit tests
//  drive it on the iOS simulator.
//
//  The trust chain, in order: the zip is verified against GitHub's own
//  SHA-256 digest from the releases JSON (ReleaseSelection), then the
//  unpacked bundle's code signature must be valid, Developer ID chained,
//  signed by this team and carry this product's bundle id (`codeRequirement`,
//  `acceptsSignature`). Only then is the installed bundle touched.
//

import Foundation

struct UpdateInstallPlan: Equatable {

    /// The Apple Developer team that signs every URnetwork build.
    static let requiredTeamIdentifier = "6BGU69Q742"
    /// The direct-download product's bundle id (TunnelProviderIdentity.direct).
    static let requiredBundleIdentifier = TunnelProviderIdentity.direct.appBundleIdentifier
    /// What the pipeline's `ditto -c -k --keepParent build/direct/URnetwork.app`
    /// unpacks to.
    static let bundleName = "URnetwork.app"
    /// macOS only runs the system extension from an app under /Applications,
    /// so that is the only place an in-place update makes sense.
    static let applicationsDirectory = SystemExtensionInstallLocation.applicationsDirectory

    /// The Security framework requirement the unpacked app must satisfy:
    /// an Apple-anchored (Developer ID) chain, this product's identifier and
    /// a leaf certificate issued to this team.
    static let codeRequirement =
        "anchor apple generic and identifier \"\(requiredBundleIdentifier)\""
        + " and certificate leaf[subject.OU] = \"\(requiredTeamIdentifier)\""

    let offer: UpdateOffer
    /// One directory per release tag under the app's temporary directory: a
    /// fresh attempt owns everything it verified, and nothing from a failed
    /// try leaks into the next.
    let workDirectory: URL

    init(offer: UpdateOffer, temporaryDirectory: URL) {
        self.offer = offer
        self.workDirectory = temporaryDirectory
            .appendingPathComponent("updates", isDirectory: true)
            .appendingPathComponent(offer.tag, isDirectory: true)
    }

    /// Where the zip is written.
    var archiveURL: URL { workDirectory.appendingPathComponent(offer.assetName) }
    /// Where `ditto -x -k` unpacks it.
    var unpackDirectory: URL { workDirectory.appendingPathComponent("unpacked", isDirectory: true) }
    /// The unpacked app bundle.
    var unpackedBundleURL: URL { unpackDirectory.appendingPathComponent(Self.bundleName, isDirectory: true) }

    /// The `ditto` invocation that unpacks the archive: the system binary by
    /// absolute path (nothing on PATH can interpose), zip mode, into the
    /// unpack directory.
    static let dittoPath = "/usr/bin/ditto"
    var dittoArguments: [String] { ["-x", "-k", archiveURL.path, unpackDirectory.path] }

    // MARK: digest

    /// Whether the downloaded archive's hash matches the release's digest.
    /// Folded, not bytewise: hex case is not worth a failure mode. Empty on
    /// either side is a mismatch, never a pass.
    static func digestMatches(actualHex: String, expectedHex: String) -> Bool {
        !actualHex.isEmpty && !expectedHex.isEmpty && actualHex.lowercased() == expectedHex.lowercased()
    }

    // MARK: unpacked bundle

    /// The one entry of the unpack directory that is the app bundle: exactly
    /// `URnetwork.app` at the top level. Anything else the archive carried
    /// (resource fork sidecars, a renamed bundle, a second bundle) is not
    /// the update.
    static func unpackedBundle(topLevelEntries entries: [String]) -> String? {
        let bundles = entries.filter { $0.hasSuffix(".app") }
        guard bundles == [bundleName] else { return nil }
        return bundleName
    }

    // MARK: signature

    /// What SecCodeCopySigningInformation reports for the unpacked bundle.
    struct SignatureIdentity: Equatable {
        let bundleIdentifier: String?
        let teamIdentifier: String?
    }

    /// Belt and braces over `codeRequirement`: the signing information must
    /// name this team and this product, exactly.
    static func acceptsSignature(_ identity: SignatureIdentity) -> Bool {
        identity.teamIdentifier == requiredTeamIdentifier
            && identity.bundleIdentifier == requiredBundleIdentifier
    }

    // MARK: replacement

    enum Strategy: Equatable {
        /// The running app is `installedBundleURL` under /Applications: move
        /// it aside (Trash, or `asideURL` when the Trash refuses) and move the
        /// verified bundle into its place, then relaunch.
        case replaceInPlace(installedBundleURL: URL, asideURL: URL)
        /// The app runs from somewhere else (the DMG, ~/Downloads, a
        /// per-user Applications folder): the system extension could not be
        /// activated from there anyway, so the verified bundle is revealed
        /// in Finder for the user to drag to Applications.
        case revealDownload
    }

    /// The replacement for an app running from `runningBundlePath`, given
    /// the running build's code (which names the aside copy).
    static func strategy(runningBundlePath: String, runningCode: UInt64) -> Strategy {
        let location = SystemExtensionInstallLocation.classify(bundlePath: runningBundlePath)
        guard location == .applications else { return .revealDownload }
        let installed = URL(fileURLWithPath: runningBundlePath).standardizedFileURL
        let aside = installed.deletingLastPathComponent()
            .appendingPathComponent(asideName(bundleName: installed.lastPathComponent, code: runningCode))
        return .replaceInPlace(installedBundleURL: installed, asideURL: aside)
    }

    /// `<bundle>.old-<code>`: where the previous bundle is parked when it
    /// cannot be trashed. The launch cleanup removes these by this exact
    /// grammar, so the name must never collide with anything a user keeps
    /// under /Applications.
    static func asideName(bundleName: String, code: UInt64) -> String {
        "\(bundleName).old-\(code)"
    }

    /// Whether `name` is one of this updater's own aside copies and nothing
    /// else: `URnetwork.app.old-<digits>`, with nothing after the digits.
    /// This gates a delete under /Applications, so a merely close match
    /// (`URnetwork.app.old-backup`, `Other.app.old-1`) is not hygiene, it is
    /// data loss.
    static func isStaleAsideName(_ name: String) -> Bool {
        let prefix = bundleName + ".old-"
        guard name.hasPrefix(prefix) else { return false }
        let digits = name.dropFirst(prefix.count)
        return !digits.isEmpty && digits.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// Whether the folder the user picked in the open panel is the
    /// Applications folder itself: the bookmark must cover the install
    /// location, not some other folder the panel happened to open on.
    static func isApplicationsFolder(_ path: String) -> Bool {
        URL(fileURLWithPath: path).standardizedFileURL.path == applicationsDirectory
    }
}
