//
//  ReleaseSelection.swift
//  URnetwork
//
//  Which official release the direct-download macOS build's in-app updater
//  offers, decided pure. The update source is the GitHub releases of ONE
//  official urnetwork repository (`repository` below, the only place it is
//  named): build/all/run.sh mints a release per build, tag
//  `v<YYYY.M.D>-<code>`, with the stapled macOS app attached as
//  `URnetwork-<YYYY.M.D>-<code>-macos.zip` next to the DMG for humans, and
//  a stable release keeps the same tag and asset names. Drafts and
//  prereleases are skipped outright (the android-only F-Droid prereleases
//  at code+2 / code+3 outrank the real release by code and carry no macOS
//  asset), as the Windows updater does
//  (windows/app/src/Common/ReleaseSelection.h).
//
//  The running build identifies itself by CFBundleShortVersionString
//  (MARKETING_VERSION = <YYYY.M.D>) and CFBundleVersion
//  (CURRENT_PROJECT_VERSION = <code>), both stamped by the release pipeline;
//  the tag is the same two values joined by "-". Ranking is by code, the
//  monotonic half. A development build (code 0) is never offered anything --
//  every release would outrank it forever -- but a manual check still reports
//  what it found. A repository with no releases yet is simply "no update".
//
//  No Foundation networking here: DirectUpdater (DIRECT_DOWNLOAD only) fetches
//  the JSON and acts on the outcome; this compiles into every build so the
//  unit tests run it on the iOS simulator.
//

import Foundation

/// A release version in the pipeline's grammar: `<YYYY.M.D>-<code>`, with an
/// optional leading `v` when it comes from a tag.
struct ReleaseVersion: Equatable, Comparable, CustomStringConvertible {
    /// The calendar half, e.g. "2026.3.23" (CFBundleShortVersionString).
    let base: String
    /// The monotonic release code, e.g. 895075980 (CFBundleVersion). 0 is a
    /// development build.
    let code: UInt64

    /// The v-less form the asset names carry (EXTERNAL_WARP_VERSION).
    var string: String { "\(base)-\(code)" }
    var description: String { string }

    var isDevelopmentBuild: Bool { code == 0 }

    static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        lhs.code < rhs.code
    }

    /// Parses `v<YYYY.M.D>-<code>` (the `v` optional). Strict on the shape:
    /// four-digit year, 1-2 digit month 1...12 and day 1...31, a dash and a
    /// decimal code of at most 18 digits; nothing may follow. Anything else is
    /// not a release tag and returns nil.
    static func parse(tag: String) -> ReleaseVersion? {
        var rest = Substring(tag)
        if rest.first == "v" {
            rest = rest.dropFirst()
        }
        guard let year = takeDigits(&rest, maxDigits: 4), year.count == 4,
              rest.first == "." else { return nil }
        rest = rest.dropFirst()
        guard let month = takeDigits(&rest, maxDigits: 2),
              let monthValue = Int(month), (1...12).contains(monthValue),
              rest.first == "." else { return nil }
        rest = rest.dropFirst()
        guard let day = takeDigits(&rest, maxDigits: 2),
              let dayValue = Int(day), (1...31).contains(dayValue),
              rest.first == "-" else { return nil }
        rest = rest.dropFirst()
        guard let codeDigits = takeDigits(&rest, maxDigits: 18),
              let code = UInt64(codeDigits),
              rest.isEmpty else { return nil }
        return ReleaseVersion(base: "\(year).\(month).\(day)", code: code)
    }

    /// The running build, from its Info.plist values. A missing or
    /// non-numeric CFBundleVersion is a development build (code 0), never an
    /// update candidate.
    static func running(shortVersion: String?, buildVersion: String?) -> ReleaseVersion {
        let base = (shortVersion ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let code = UInt64((buildVersion ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        return ReleaseVersion(base: base.isEmpty ? "0.0.0" : base, code: code)
    }

    /// The leading decimal run of `s`, consumed, or nil when it is empty or
    /// longer than `maxDigits` (a refusal, not a truncation).
    private static func takeDigits(_ s: inout Substring, maxDigits: Int) -> String? {
        let run = s.prefix { $0.isASCII && $0.isNumber }
        guard !run.isEmpty, run.count <= maxDigits else { return nil }
        s = s.dropFirst(run.count)
        return String(run)
    }
}

/// One asset of a GitHub release, as the releases API describes it.
struct ReleaseAsset: Equatable {
    let name: String
    /// browser_download_url
    let url: String
    /// The API's `sha256:<hex>`, verbatim; nil when absent.
    let digest: String?
}

/// One GitHub release, reduced to what the decision needs.
struct Release: Equatable {
    let tag: String
    let draft: Bool
    let prerelease: Bool
    let assets: [ReleaseAsset]
}

/// Everything an install needs, captured at check time so a repo that
/// changes mid-flight cannot redirect it: the URL and the expected hash come
/// from the SAME asset object.
struct UpdateOffer: Equatable {
    let version: ReleaseVersion
    /// As minted, with the v.
    let tag: String
    let assetName: String
    let assetURL: URL
    /// Lowercase SHA-256 hex.
    let digestHex: String
}

enum ReleaseSelection {

    /// The official release repository, and the only update source. Never a
    /// fork.
    static let repository = "urnetwork/build"

    /// The newest releases, drafts and prereleases included (filtered here).
    /// The list rather than `releases/latest`: a repository with no release
    /// yet answers 404 there, and a newest release that cannot be verified
    /// must not hide an older one that can.
    static let releasesPerPage = 15
    static let releasesURL = URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=\(releasesPerPage)")!

    /// The zip asset the release pipeline uploads for `version` (v-less):
    /// URnetwork-<version>-macos.zip (one universal archive).
    static func assetName(version: String) -> String {
        "URnetwork-\(version)-macos.zip"
    }

    /// The lowercase SHA-256 hex out of an asset's `digest`, or nil when the
    /// value is not exactly `sha256:<64 hex chars>`. Another algorithm, a
    /// missing prefix, truncated or padded hex are refusals: nil means "this
    /// release cannot be verified", never best effort.
    static func digestHex(fromAssetDigest digest: String?) -> String? {
        guard let digest else { return nil }
        let prefix = "sha256:"
        guard digest.count == prefix.count + 64, digest.hasPrefix(prefix) else { return nil }
        let hex = digest.dropFirst(prefix.count).lowercased()
        guard hex.allSatisfy({ $0.isHexDigit && $0.isASCII }) else { return nil }
        return hex
    }

    enum Outcome: Equatable {
        /// No release outranks the running build. `newest` is the newest
        /// release that parsed, nil when the repository has none yet (an
        /// empty list, or 404): not an error, just nothing to offer.
        case upToDate(newest: ReleaseVersion?)
        /// A release outranks this development build, which never self-updates.
        case developmentBuild(newest: ReleaseVersion)
        /// The newest release the app can download and verify, which
        /// outranks the running build.
        case available(UpdateOffer)
        /// Releases outrank the running build but none of them can be
        /// offered; `reasons` say why, newest first (for the log and the
        /// Settings row).
        case unusable(newest: ReleaseVersion, reasons: [String])
    }

    /// Why one release could not be offered, or the offer. Pure per release.
    private static func offer(for release: Release, version: ReleaseVersion) -> Result<UpdateOffer, Skip> {
        let name = assetName(version: version.string)
        guard let asset = release.assets.last(where: { $0.name == name }) else {
            return .failure(Skip(reason: "release \(release.tag) lacks \(name)"))
        }
        guard let url = URL(string: asset.url), url.scheme == "https" else {
            return .failure(Skip(reason: "release \(release.tag) has no https download for \(name)"))
        }
        guard let digestHex = digestHex(fromAssetDigest: asset.digest) else {
            return .failure(Skip(reason: "release \(release.tag) lacks a usable sha256 digest for \(name)"))
        }
        return .success(UpdateOffer(version: version, tag: release.tag, assetName: name, assetURL: url, digestHex: digestHex))
    }

    private struct Skip: Error {
        let reason: String
    }

    /// The decision for the release list, in any order. Drafts, prereleases
    /// and tags outside the grammar are ignored. Two maxima, deliberately
    /// separate, as on Windows: the newest release that PARSES (the honest
    /// answer to "is there something newer") and the newest release this
    /// build can actually VERIFY (zip attached with a usable digest); when a
    /// newer release is broken, an older verifiable one that still outranks
    /// the running build is offered instead.
    static func select(releases: [Release], running: ReleaseVersion) -> Outcome {
        let parsed = releases
            .filter { !$0.draft && !$0.prerelease }
            .compactMap { release in ReleaseVersion.parse(tag: release.tag).map { (release, $0) } }
            .sorted { $0.1.code > $1.1.code }
        guard let newest = parsed.first?.1 else {
            return .upToDate(newest: nil)
        }
        if running.isDevelopmentBuild {
            return .developmentBuild(newest: newest)
        }
        guard running < newest else {
            return .upToDate(newest: newest)
        }
        var reasons: [String] = []
        for (release, version) in parsed where running < version {
            switch offer(for: release, version: version) {
            case .success(let offer):
                return .available(offer)
            case .failure(let skip):
                reasons.append(skip.reason)
            }
        }
        return .unusable(newest: newest, reasons: reasons)
    }

    /// The releases list body as Releases, or nil when it is not a JSON
    /// array. Entries that are not objects with a string tag_name are
    /// dropped; every other field is read defensively, the shape being
    /// another service's: a missing or mistyped `draft` is false, a missing
    /// `digest` is nil.
    static func parse(releasesJSON data: Data) -> [Release]? {
        guard let array = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else { return nil }
        return array.compactMap { entry -> Release? in
            guard let object = entry as? [String: Any],
                  let tag = object["tag_name"] as? String else { return nil }
            let assets = ((object["assets"] as? [Any]) ?? []).compactMap { entry -> ReleaseAsset? in
                guard let asset = entry as? [String: Any],
                      let name = asset["name"] as? String else { return nil }
                return ReleaseAsset(
                    name: name,
                    url: (asset["browser_download_url"] as? String) ?? "",
                    digest: asset["digest"] as? String
                )
            }
            return Release(
                tag: tag,
                draft: (object["draft"] as? Bool) ?? false,
                prerelease: (object["prerelease"] as? Bool) ?? false,
                assets: assets
            )
        }
    }
}

/// When the automatic launch check runs: at most once per `interval`,
/// measured from the last completed check, manual or automatic (two checks
/// minutes apart cannot say different things).
enum UpdateCheckSchedule {
    static let interval: TimeInterval = 6 * 60 * 60

    static func isDue(lastCheck: Date?, now: Date, interval: TimeInterval = interval) -> Bool {
        guard let lastCheck else { return true }
        // a clock that went backwards (lastCheck in the future) is not a
        // reason to wait another six hours
        return now.timeIntervalSince(lastCheck) >= interval || lastCheck > now
    }
}
