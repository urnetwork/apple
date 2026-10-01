//
//  ReleaseSelectionTests.swift
//  networkTests
//
//  The direct-download macOS build's in-app updater decides what to offer
//  with the pure ReleaseSelection (network/Shared/Updater/ReleaseSelection.swift):
//  the tag grammar, the `releases/latest` JSON, draft/prerelease refusal,
//  the own asset by name, the digest grammar, and ranking against the
//  running build. These pin it against the names the release pipeline
//  actually publishes (build/all/run.sh), and pin the update source to the
//  official repository.
//

import Testing
import Foundation
@testable import URnetwork

struct ReleaseSelectionTests {

    // MARK: the update source

    @Test func theUpdateSourceIsTheOfficialRepositoryAndNothingElse() {
        #expect(ReleaseSelection.repository == "urnetwork/apple")
        // the nightly feed and personal forks are never the update source
        #expect(ReleaseSelection.repository != "urnetwork/build")
        #expect(ReleaseSelection.repository.hasPrefix("urnetwork/"))
        #expect(ReleaseSelection.releasesURL.absoluteString
                == "https://api.github.com/repos/urnetwork/apple/releases?per_page=15")
        #expect(ReleaseSelection.releasesURL.scheme == "https")
        #expect(ReleaseSelection.releasesURL.host == "api.github.com")
        // negative control: an official urnetwork repository, never a
        // personal fork or another owner
        #expect(ReleaseSelection.repository.hasPrefix("urnetwork/"))
        #expect(!ReleaseSelection.releasesURL.path.contains("bringyour/"))
        #expect(!ReleaseSelection.releasesURL.path.contains("xcolwell/"))
    }

    // MARK: tag grammar

    @Test func theReleaseTagGrammarParses() throws {
        let version = try #require(ReleaseVersion.parse(tag: "v2026.3.23-895075980"))
        #expect(version.base == "2026.3.23")
        #expect(version.code == 895075980)
        #expect(version.string == "2026.3.23-895075980")
        #expect(!version.isDevelopmentBuild)
        // the v is optional (CFBundleShortVersionString + CFBundleVersion carry none)
        #expect(ReleaseVersion.parse(tag: "2026.12.31-1") == ReleaseVersion(base: "2026.12.31", code: 1))
    }

    @Test func nonReleaseTagsAreRefused() {
        for tag in ["", "v", "v1.2.3", "v2026.3.23", "v2026.3.23-", "v2026.3.23-abc", "v2026.3.23-895075980-beta",
                    "v2026.13.1-5", "v2026.0.1-5", "v2026.3.32-5", "v26.3.23-5", "v2026.3.23-1234567890123456789",
                    "v2026.3.23-895075980 ", "latest"] {
            #expect(ReleaseVersion.parse(tag: tag) == nil, "\(tag) parsed")
        }
    }

    @Test func versionsRankByCode() {
        let older = ReleaseVersion(base: "2026.3.23", code: 895075980)
        let newer = ReleaseVersion(base: "2026.4.1", code: 895075999)
        #expect(older < newer)
        #expect(!(newer < older))
        #expect(!(older < older))
    }

    @Test func theRunningBuildComesFromItsInfoPlist() {
        #expect(ReleaseVersion.running(shortVersion: "2026.3.23", buildVersion: "895075980")
                == ReleaseVersion(base: "2026.3.23", code: 895075980))
        // the project's defaults (MARKETING_VERSION 0.0.0 / CURRENT_PROJECT_VERSION 0) are a dev build
        #expect(ReleaseVersion.running(shortVersion: "0.0.0", buildVersion: "0").isDevelopmentBuild)
        #expect(ReleaseVersion.running(shortVersion: nil, buildVersion: nil).isDevelopmentBuild)
        #expect(ReleaseVersion.running(shortVersion: "2026.3.23", buildVersion: "not a number").isDevelopmentBuild)
    }

    // MARK: asset name and digest

    @Test func theAssetNameIsWhatThePipelineUploads() {
        #expect(ReleaseSelection.assetName(version: "2026.3.23-895075980") == "URnetwork-2026.3.23-895075980-macos.zip")
    }

    @Test func theDigestMustBeExactlySha256Hex() {
        let hex = String(repeating: "ab", count: 32)
        #expect(ReleaseSelection.digestHex(fromAssetDigest: "sha256:" + hex) == hex)
        // canonicalized to lowercase
        #expect(ReleaseSelection.digestHex(fromAssetDigest: "sha256:" + hex.uppercased()) == hex)
        for bad in [nil, "", hex, "sha512:" + hex + hex, "sha256:" + String(hex.dropLast()), "sha256:" + hex + "0",
                    "sha256:" + String(repeating: "zz", count: 32), "SHA256:" + hex] {
            #expect(ReleaseSelection.digestHex(fromAssetDigest: bad) == nil, "\(bad ?? "nil") accepted")
        }
    }

    // MARK: fixtures

    static let running = ReleaseVersion(base: "2026.3.23", code: 895075980)
    static let goodDigest = "sha256:" + String(repeating: "0f", count: 32)

    static func release(
        tag: String,
        draft: Bool = false,
        prerelease: Bool = false,
        assets: [ReleaseAsset]? = nil
    ) -> Release {
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return Release(tag: tag, draft: draft, prerelease: prerelease, assets: assets ?? [
            ReleaseAsset(name: "URnetwork-\(version)-x64.msi",
                         url: "https://github.com/urnetwork/apple/releases/download/\(tag)/URnetwork-\(version)-x64.msi",
                         digest: goodDigest),
            ReleaseAsset(name: "URnetwork-\(version)-macos.dmg",
                         url: "https://github.com/urnetwork/apple/releases/download/\(tag)/URnetwork-\(version)-macos.dmg",
                         digest: goodDigest),
            ReleaseAsset(name: "URnetwork-\(version)-macos.zip",
                         url: "https://github.com/urnetwork/apple/releases/download/\(tag)/URnetwork-\(version)-macos.zip",
                         digest: goodDigest),
        ])
    }

    // MARK: selection

    @Test func aNewerReleaseWithTheMacOSZipIsOffered() throws {
        let outcome = ReleaseSelection.select(releases: [Self.release(tag: "v2026.4.1-895076000")], running: Self.running)
        guard case .available(let offer) = outcome else {
            Issue.record("expected an offer, got \(outcome)")
            return
        }
        #expect(offer.version == ReleaseVersion(base: "2026.4.1", code: 895076000))
        #expect(offer.tag == "v2026.4.1-895076000")
        #expect(offer.assetName == "URnetwork-2026.4.1-895076000-macos.zip")
        #expect(offer.assetURL.absoluteString
                == "https://github.com/urnetwork/apple/releases/download/v2026.4.1-895076000/URnetwork-2026.4.1-895076000-macos.zip")
        #expect(offer.digestHex == String(repeating: "0f", count: 32))
    }

    @Test func theNewestOfSeveralIsOfferedWhateverTheListOrder() {
        let releases = [
            Self.release(tag: "v2026.3.30-895075990"),
            Self.release(tag: "v2026.4.1-895076000"),
            Self.release(tag: "v2026.3.24-895075985"),
        ]
        for ordered in [releases, releases.reversed()] {
            guard case .available(let offer) = ReleaseSelection.select(releases: ordered, running: Self.running) else {
                Issue.record("no offer")
                return
            }
            #expect(offer.tag == "v2026.4.1-895076000")
        }
    }

    @Test func theSameOrAnOlderReleaseIsUpToDate() {
        #expect(ReleaseSelection.select(releases: [Self.release(tag: "v2026.3.23-895075980")], running: Self.running)
                == .upToDate(newest: Self.running))
        #expect(ReleaseSelection.select(releases: [Self.release(tag: "v2026.3.1-895075900"), Self.release(tag: "v2026.2.1-895075800")], running: Self.running)
                == .upToDate(newest: ReleaseVersion(base: "2026.3.1", code: 895075900)))
    }

    @Test func noReleasesAtAllIsUpToDateNotAnError() {
        #expect(ReleaseSelection.select(releases: [], running: Self.running) == .upToDate(newest: nil))
        #expect(ReleaseSelection.select(releases: [], running: ReleaseVersion(base: "0.0.0", code: 0)) == .upToDate(newest: nil))
        // only drafts, prereleases and foreign tags is the same as none
        let ignored = [
            Self.release(tag: "v2026.4.1-895076000", draft: true),
            Self.release(tag: "v2026.4.1-895076002", prerelease: true),
            Self.release(tag: "v1.2.3"),
        ]
        #expect(ReleaseSelection.select(releases: ignored, running: Self.running) == .upToDate(newest: nil))
    }

    @Test func draftsAndPrereleasesAreNeverOffered() {
        // the android-only F-Droid prerelease at code+2 outranks the real
        // release and would otherwise be "the newest release"
        let releases = [
            Self.release(tag: "v2026.4.1-895076003", prerelease: true),
            Self.release(tag: "v2026.4.1-895076002", prerelease: true),
            Self.release(tag: "v2026.4.2-895076100", draft: true),
            Self.release(tag: "v2026.4.1-895076000"),
        ]
        guard case .available(let offer) = ReleaseSelection.select(releases: releases, running: Self.running) else {
            Issue.record("no offer")
            return
        }
        #expect(offer.tag == "v2026.4.1-895076000")

        let draftOnly = ReleaseSelection.select(releases: [Self.release(tag: "v2026.4.1-895076000", draft: true)], running: Self.running)
        #expect(draftOnly == .upToDate(newest: nil))
    }

    @Test func aBrokenNewestReleaseFallsBackToAnOlderVerifiableOne() {
        let broken = "2026.4.2-895076100"
        let releases = [
            Self.release(tag: "v" + broken, assets: [
                ReleaseAsset(name: "URnetwork-\(broken)-macos.dmg", url: "https://example.test/macos.dmg", digest: Self.goodDigest),
            ]),
            Self.release(tag: "v2026.4.1-895076000"),
        ]
        guard case .available(let offer) = ReleaseSelection.select(releases: releases, running: Self.running) else {
            Issue.record("no offer")
            return
        }
        #expect(offer.tag == "v2026.4.1-895076000")
    }

    @Test func aNewerReleaseWithoutTheMacOSZipIsReportedNotOffered() {
        let version = "2026.4.1-895076000"
        let release = Self.release(tag: "v" + version, assets: [
            ReleaseAsset(name: "URnetwork-\(version)-x64.msi", url: "https://example.test/x64.msi", digest: Self.goodDigest),
            ReleaseAsset(name: "URnetwork-\(version)-macos.dmg", url: "https://example.test/macos.dmg", digest: Self.goodDigest),
            // the right suffix on the wrong version is not the asset
            ReleaseAsset(name: "URnetwork-2026.3.23-895075980-macos.zip", url: "https://example.test/old.zip", digest: Self.goodDigest),
        ])
        // an older verifiable release does not count: it does not outrank the running build
        let outcome = ReleaseSelection.select(releases: [release, Self.release(tag: "v2026.3.1-895075900")], running: Self.running)
        #expect(outcome == .unusable(newest: ReleaseVersion(base: "2026.4.1", code: 895076000),
                                     reasons: ["release v2026.4.1-895076000 lacks URnetwork-2026.4.1-895076000-macos.zip"]))
    }

    @Test func aNewerReleaseWithABadDigestIsNotOffered() {
        let version = "2026.4.1-895076000"
        for digest in [nil, "", "sha512:" + String(repeating: "0f", count: 64), "sha256:" + String(repeating: "0f", count: 31)] {
            let release = Self.release(tag: "v" + version, assets: [
                ReleaseAsset(name: "URnetwork-\(version)-macos.zip", url: "https://example.test/macos.zip", digest: digest),
            ])
            let outcome = ReleaseSelection.select(releases: [release], running: Self.running)
            guard case .unusable(let newest, let reasons) = outcome else {
                Issue.record("digest \(digest ?? "nil") was accepted: \(outcome)")
                continue
            }
            #expect(newest == ReleaseVersion(base: "2026.4.1", code: 895076000))
            #expect(reasons.count == 1)
            #expect(reasons[0].contains("digest"))
        }
    }

    @Test func aNonHttpsDownloadIsNotOffered() {
        let version = "2026.4.1-895076000"
        let release = Self.release(tag: "v" + version, assets: [
            ReleaseAsset(name: "URnetwork-\(version)-macos.zip", url: "http://example.test/macos.zip", digest: Self.goodDigest),
        ])
        guard case .unusable = ReleaseSelection.select(releases: [release], running: Self.running) else {
            Issue.record("an http download was offered")
            return
        }
    }

    @Test func aDevelopmentBuildIsToldButNeverOffered() {
        let dev = ReleaseVersion(base: "0.0.0", code: 0)
        #expect(ReleaseSelection.select(releases: [Self.release(tag: "v2026.4.1-895076000")], running: dev)
                == .developmentBuild(newest: ReleaseVersion(base: "2026.4.1", code: 895076000)))
    }

    // MARK: JSON

    static let releasesJSON = """
    [
      {
        "url": "https://api.github.com/repos/urnetwork/apple/releases/2",
        "tag_name": "v2026.4.1-895076002",
        "draft": false,
        "prerelease": true,
        "assets": [{"name": "com.bringyour.network-895076002.apk", "browser_download_url": "https://example.test/a.apk", "digest": null}]
      },
      {
        "url": "https://api.github.com/repos/urnetwork/apple/releases/1",
        "tag_name": "v2026.4.1-895076000",
        "name": "2026.4.1-895076000",
        "draft": false,
        "prerelease": false,
        "assets": [
          {"name": "URnetwork-2026.4.1-895076000-x64.msi", "browser_download_url": "https://github.com/urnetwork/apple/releases/download/v2026.4.1-895076000/URnetwork-2026.4.1-895076000-x64.msi", "digest": "sha256:\(String(repeating: "1a", count: 32))", "size": 1},
          {"name": "URnetwork-2026.4.1-895076000-macos.dmg", "browser_download_url": "https://github.com/urnetwork/apple/releases/download/v2026.4.1-895076000/URnetwork-2026.4.1-895076000-macos.dmg", "digest": null, "size": 2},
          {"name": "URnetwork-2026.4.1-895076000-macos.zip", "browser_download_url": "https://github.com/urnetwork/apple/releases/download/v2026.4.1-895076000/URnetwork-2026.4.1-895076000-macos.zip", "digest": "sha256:\(String(repeating: "2B", count: 32))", "size": 3},
          {"name": 42, "browser_download_url": "https://example.test/not-an-asset"},
          "not an object"
        ]
      },
      {"tag_name": 7},
      "not a release"
    ]
    """

    @Test func theReleaseListJSONParsesIntoReleases() throws {
        let releases = try #require(ReleaseSelection.parse(releasesJSON: Data(Self.releasesJSON.utf8)))
        #expect(releases.count == 2)
        #expect(releases[0].prerelease)
        let release = releases[1]
        #expect(release.tag == "v2026.4.1-895076000")
        #expect(!release.draft)
        #expect(!release.prerelease)
        #expect(release.assets.count == 3)
        #expect(release.assets[1].digest == nil)
        #expect(release.assets[2] == ReleaseAsset(
            name: "URnetwork-2026.4.1-895076000-macos.zip",
            url: "https://github.com/urnetwork/apple/releases/download/v2026.4.1-895076000/URnetwork-2026.4.1-895076000-macos.zip",
            digest: "sha256:" + String(repeating: "2B", count: 32)
        ))

        // end to end: the prerelease is skipped and the offer carries the
        // lowercase hex of the zip's digest
        guard case .available(let offer) = ReleaseSelection.select(releases: releases, running: Self.running) else {
            Issue.record("the parsed release was not offered")
            return
        }
        #expect(offer.tag == "v2026.4.1-895076000")
        #expect(offer.digestHex == String(repeating: "2b", count: 32))
    }

    @Test func mistypedFlagsReadAsAbsent() throws {
        let json = """
        [{"tag_name": "v2026.4.1-895076000", "draft": "yes", "prerelease": null, "assets": "none"}]
        """
        let releases = try #require(ReleaseSelection.parse(releasesJSON: Data(json.utf8)))
        #expect(releases.count == 1)
        #expect(!releases[0].draft)
        #expect(!releases[0].prerelease)
        #expect(releases[0].assets.isEmpty)
    }

    @Test func anEmptyListParsesToNoReleases() throws {
        let releases = try #require(ReleaseSelection.parse(releasesJSON: Data("[]".utf8)))
        #expect(releases.isEmpty)
    }

    @Test func aBodyThatIsNotAListIsRefused() {
        for body in ["", "not json", "{}", #"{"tag_name": "v2026.4.1-895076000"}"#, #"{"message": "Not Found"}"#] {
            #expect(ReleaseSelection.parse(releasesJSON: Data(body.utf8)) == nil, "\(body) parsed")
        }
    }

    // MARK: cadence

    @Test func theLaunchCheckRunsAtMostOncePerSixHours() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(UpdateCheckSchedule.interval == 6 * 60 * 60)
        #expect(UpdateCheckSchedule.isDue(lastCheck: nil, now: now))
        #expect(!UpdateCheckSchedule.isDue(lastCheck: now.addingTimeInterval(-60), now: now))
        #expect(!UpdateCheckSchedule.isDue(lastCheck: now.addingTimeInterval(-6 * 60 * 60 + 1), now: now))
        #expect(UpdateCheckSchedule.isDue(lastCheck: now.addingTimeInterval(-6 * 60 * 60), now: now))
        #expect(UpdateCheckSchedule.isDue(lastCheck: now.addingTimeInterval(-7 * 24 * 60 * 60), now: now))
        // a clock that went backwards does not postpone the check
        #expect(UpdateCheckSchedule.isDue(lastCheck: now.addingTimeInterval(60 * 60), now: now))
    }
}
