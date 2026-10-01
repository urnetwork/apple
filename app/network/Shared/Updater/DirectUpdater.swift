//
//  DirectUpdater.swift
//  URnetwork
//
//  Direct-download macOS build only (`DIRECT_DOWNLOAD`): the in-app updater.
//  The App Store build updates through the store and does not compile this.
//
//  Mirrors the Windows updater (windows/app/src/App/UpdateChecker.cpp): poll
//  the official GitHub releases (ReleaseSelection.releasesURL) at launch
//  -- at most once per six hours, user-disableable in Settings -- and on the
//  Settings button, and when a release outranks this build offer ONE click
//  that
//
//    downloads URnetwork-<version>-macos.zip into the app's temporary
//      directory with URLSession,
//    verifies it against the asset's own SHA-256 digest from the same
//      releases JSON (CryptoKit, locally; a mismatch deletes the file),
//    unpacks it with /usr/bin/ditto -x -k,
//    verifies the unpacked app's code signature with the Security framework
//      (valid, strict, nested code; Developer ID chain; this team; this
//      bundle id -- UpdateInstallPlan.codeRequirement),
//    and installs it: the sandbox cannot write /Applications, so the user
//      grants a security-scoped bookmark to the Applications folder once
//      (NSOpenPanel preset to it; persisted app-scoped), the running bundle
//      goes to the Trash (or aside, `URnetwork.app.old-<code>`, when the
//      Trash refuses) and the verified bundle takes its place, then the app
//      relaunches from there and quits.
//
//  An app not running from /Applications cannot be replaced in place (and
//  could not activate its system extension from there anyway): the verified
//  bundle is revealed in Finder with instructions instead. The system
//  extension inside the new bundle is activated on the next launch by
//  SystemExtensionActivator's replacement path.
//
//  The decisions (release ranking, digest grammar, paths, signature
//  acceptance, replacement strategy) are pure and unit-tested in
//  ReleaseSelection.swift and UpdateInstallPlan.swift; this file executes
//  them and holds the state the Settings row renders.
//

#if os(macOS) && DIRECT_DOWNLOAD

import Foundation
import AppKit
import CryptoKit
import Security

@MainActor
final class DirectUpdater: ObservableObject {

    enum Failure: Equatable {
        case check(String)
        /// Newer releases exist but none carries a verifiable macOS zip.
        case unusableRelease(newest: ReleaseVersion, reason: String)
        case download(String)
        case checksum
        case unpack(String)
        case signature(String)
        case access(String)
        case install(String)
    }

    /// What the Settings row shows. One phase, not flags: every phase names
    /// exactly one rendering.
    enum Phase: Equatable {
        case idle
        case checking
        /// Nothing newer; `newest` is nil when there are no releases yet.
        case upToDate(newest: ReleaseVersion?)
        /// A release outranks this development build (code 0); nothing is
        /// offered.
        case developmentBuild(newest: ReleaseVersion)
        case available(UpdateOffer)
        case downloading(UpdateOffer)
        case verifying(UpdateOffer)
        case installing(UpdateOffer)
        case relaunching(UpdateOffer)
        /// Downloaded and verified, but the app is not under /Applications:
        /// the bundle was revealed in Finder for the user to drag.
        case manualInstall(UpdateOffer, bundleURL: URL)
        /// The last check or install failed. Nothing was installed; the
        /// button retries from scratch.
        case failed(UpdateOffer?, Failure)

        var offer: UpdateOffer? {
            switch self {
            case .available(let offer), .downloading(let offer), .verifying(let offer),
                 .installing(let offer), .relaunching(let offer), .manualInstall(let offer, _):
                return offer
            case .failed(let offer, _):
                return offer
            case .idle, .checking, .upToDate, .developmentBuild:
                return nil
            }
        }

        var isBusy: Bool {
            switch self {
            case .checking, .downloading, .verifying, .installing, .relaunching:
                return true
            default:
                return false
            }
        }
    }

    static let automaticChecksKey = "directUpdater.automaticChecks"
    static let lastCheckKey = "directUpdater.lastCheck"
    static let applicationsBookmarkKey = "directUpdater.applicationsBookmark"
    /// The launch check waits out the startup rush (SDK init, extension
    /// activation) rather than adding a request to it.
    static let launchDelay: TimeInterval = 20
    /// Response caps: the release JSON is a few hundred KB at most; the zip
    /// is tens of MB. A larger body is refused, not streamed into a file.
    static let maxJSONBytes = 8 * 1024 * 1024
    static let maxArchiveBytes: Int64 = 1024 * 1024 * 1024

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastCheck: Date?
    @Published var automaticChecksEnabled: Bool {
        didSet {
            defaults.set(automaticChecksEnabled, forKey: Self.automaticChecksKey)
            // the user just asked for updates; answer now, not in six hours
            if automaticChecksEnabled && !oldValue && !phase.isBusy {
                checkNow()
            }
        }
    }

    /// This build, from its Info.plist.
    let runningVersion: ReleaseVersion

    private let defaults: UserDefaults
    private let session: URLSession
    private var work: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.runningVersion = ReleaseVersion.running(
            shortVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            buildVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        )
        self.automaticChecksEnabled = defaults.object(forKey: Self.automaticChecksKey) as? Bool ?? true
        self.lastCheck = defaults.object(forKey: Self.lastCheckKey) as? Date
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 15 * 60
        configuration.httpAdditionalHeaders = [
            "User-Agent": "URnetwork-macOS/\(runningVersion.string)",
        ]
        self.session = URLSession(configuration: configuration)
    }

    // MARK: triggers

    /// The launch check: after a short delay, only when automatic checks are
    /// on and the last completed check is older than the cadence.
    func checkAtLaunchIfDue() {
        cleanUpStaleAsideBundles()
        guard automaticChecksEnabled,
              UpdateCheckSchedule.isDue(lastCheck: lastCheck, now: Date()) else { return }
        guard work == nil else { return }
        work = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.launchDelay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            await self.runCheck()
            self.work = nil
        }
    }

    /// The Settings button.
    func checkNow() {
        guard !phase.isBusy else { return }
        work?.cancel()
        work = Task { [weak self] in
            guard let self else { return }
            await self.runCheck()
            self.work = nil
        }
    }

    /// The one click.
    func install() {
        guard let offer = phase.offer, !phase.isBusy else { return }
        work?.cancel()
        work = Task { [weak self] in
            guard let self else { return }
            await self.runInstall(offer)
            self.work = nil
        }
    }

    /// The manual-install row's re-reveal action.
    func revealDownload() {
        if case .manualInstall(_, let bundleURL) = phase {
            NSWorkspace.shared.activateFileViewerSelecting([bundleURL])
        }
    }

    // MARK: the check

    private func runCheck() async {
        let standing = phase
        phase = .checking
        do {
            var request = URLRequest(url: ReleaseSelection.releasesURL)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw CheckError("no HTTP response")
            }
            let releases: [Release]
            if http.statusCode == 404 {
                // a repository without releases yet: nothing to offer, not
                // an error
                releases = []
            } else {
                guard http.statusCode == 200 else {
                    throw CheckError("http status \(http.statusCode)")
                }
                guard data.count <= Self.maxJSONBytes else {
                    throw CheckError("release JSON larger than the \(Self.maxJSONBytes) byte cap")
                }
                guard let parsed = ReleaseSelection.parse(releasesJSON: data) else {
                    throw CheckError("release list was not a JSON array")
                }
                releases = parsed
            }
            recordCheck()
            switch ReleaseSelection.select(releases: releases, running: runningVersion) {
            case .upToDate(let newest):
                phase = .upToDate(newest: newest)
            case .developmentBuild(let newest):
                phase = .developmentBuild(newest: newest)
            case .available(let offer):
                // the SAME release keeps its standing manual-install or
                // failed state: a periodic check must not wipe the outcome
                // of a click
                if let standingOffer = standing.offer, standingOffer == offer,
                   !(standing == .available(offer)) {
                    phase = standing
                } else {
                    phase = .available(offer)
                }
            case .unusable(let newest, let reasons):
                phase = .failed(nil, .unusableRelease(newest: newest, reason: reasons.first ?? ""))
            }
        } catch {
            recordCheck()
            phase = .failed(nil, .check(describe(error)))
        }
    }

    private struct CheckError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    private func recordCheck() {
        let now = Date()
        lastCheck = now
        defaults.set(now, forKey: Self.lastCheckKey)
    }

    // MARK: the install

    private func runInstall(_ offer: UpdateOffer) async {
        let plan = UpdateInstallPlan(offer: offer, temporaryDirectory: FileManager.default.temporaryDirectory)
        let fileManager = FileManager.default

        // (a) download into a fresh per-tag directory
        phase = .downloading(offer)
        do {
            try? fileManager.removeItem(at: plan.workDirectory)
            try fileManager.createDirectory(at: plan.workDirectory, withIntermediateDirectories: true)
            let (downloaded, response) = try await session.download(from: offer.assetURL)
            defer { try? fileManager.removeItem(at: downloaded) }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw CheckError("http status \((response as? HTTPURLResponse)?.statusCode ?? 0)")
            }
            let size = (try? fileManager.attributesOfItem(atPath: downloaded.path)[.size] as? Int64) ?? 0
            guard size <= Self.maxArchiveBytes else {
                throw CheckError("archive larger than the \(Self.maxArchiveBytes) byte cap")
            }
            try fileManager.moveItem(at: downloaded, to: plan.archiveURL)
        } catch {
            phase = .failed(offer, .download(describe(error)))
            return
        }

        // (b) verify against the asset's digest. The unverifiable download
        // does not stay on disk.
        phase = .verifying(offer)
        let actualHex = await Task.detached(priority: .userInitiated) {
            Self.sha256Hex(of: plan.archiveURL)
        }.value
        guard UpdateInstallPlan.digestMatches(actualHex: actualHex, expectedHex: offer.digestHex) else {
            try? fileManager.removeItem(at: plan.workDirectory)
            phase = .failed(offer, .checksum)
            return
        }

        // (c) unpack with ditto, then insist on exactly URnetwork.app
        do {
            try? fileManager.removeItem(at: plan.unpackDirectory)
            try fileManager.createDirectory(at: plan.unpackDirectory, withIntermediateDirectories: true)
            try await Self.runDitto(arguments: plan.dittoArguments)
            let entries = try fileManager.contentsOfDirectory(atPath: plan.unpackDirectory.path)
            guard UpdateInstallPlan.unpackedBundle(topLevelEntries: entries) != nil else {
                throw CheckError("the archive did not unpack to \(UpdateInstallPlan.bundleName)")
            }
        } catch {
            try? fileManager.removeItem(at: plan.workDirectory)
            phase = .failed(offer, .unpack(describe(error)))
            return
        }

        // (d) the unpacked app's signature
        if let problem = Self.signatureProblem(bundleURL: plan.unpackedBundleURL) {
            try? fileManager.removeItem(at: plan.workDirectory)
            phase = .failed(offer, .signature(problem))
            return
        }

        // (e) install
        switch UpdateInstallPlan.strategy(runningBundlePath: Bundle.main.bundlePath, runningCode: runningVersion.code) {
        case .revealDownload:
            phase = .manualInstall(offer, bundleURL: plan.unpackedBundleURL)
            NSWorkspace.shared.activateFileViewerSelecting([plan.unpackedBundleURL])
        case .replaceInPlace(let installed, let aside):
            phase = .installing(offer)
            guard let applications = applicationsFolderAccess() else {
                phase = .failed(offer, .access("Access to the Applications folder was not granted."))
                return
            }
            defer { applications.stopAccessingSecurityScopedResource() }
            do {
                try Self.replace(installed: installed, with: plan.unpackedBundleURL, aside: aside)
            } catch {
                phase = .failed(offer, .install(describe(error)))
                return
            }
            phase = .relaunching(offer)
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: installed, configuration: configuration) { _, _ in
                DispatchQueue.main.async {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
    }

    // MARK: pieces

    nonisolated static func sha256Hex(of file: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return "" }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            guard let chunk = try? handle.read(upToCount: 1024 * 1024), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func runDitto(arguments: [String]) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: UpdateInstallPlan.dittoPath)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        let errorPipe = Pipe()
        process.standardError = errorPipe
        // the handler is installed before the launch: one installed after a
        // process that already exited never fires
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
        if status != 0 {
            let message = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw CheckError("ditto exited \(status): \(message.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    /// nil when the bundle at `bundleURL` satisfies UpdateInstallPlan's
    /// requirement under strict, nested, all-architecture validation and its
    /// signing information names this team and product; otherwise why not.
    nonisolated static func signatureProblem(bundleURL: URL) -> String? {
        var staticCode: SecStaticCode?
        var status = SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &staticCode)
        guard status == errSecSuccess, let code = staticCode else {
            return "the unpacked app could not be read for signature checking (\(status))"
        }
        var requirement: SecRequirement?
        status = SecRequirementCreateWithString(UpdateInstallPlan.codeRequirement as CFString, [], &requirement)
        guard status == errSecSuccess, let requirement else {
            return "the signing requirement could not be compiled (\(status))"
        }
        let flags = SecCSFlags(rawValue: UInt32(kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate))
        var validityError: Unmanaged<CFError>?
        status = SecStaticCodeCheckValidityWithErrors(code, flags, requirement, &validityError)
        if status != errSecSuccess {
            let detail = validityError?.takeRetainedValue().localizedDescription ?? "code \(status)"
            return "the unpacked app is not a valid URnetwork build signed by the developer: \(detail)"
        }
        var information: CFDictionary?
        status = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: UInt32(kSecCSSigningInformation)), &information)
        guard status == errSecSuccess, let info = information as? [String: Any] else {
            return "the unpacked app's signing information could not be read (\(status))"
        }
        let identity = UpdateInstallPlan.SignatureIdentity(
            bundleIdentifier: info[kSecCodeInfoIdentifier as String] as? String,
            teamIdentifier: info[kSecCodeInfoTeamIdentifier as String] as? String
        )
        guard UpdateInstallPlan.acceptsSignature(identity) else {
            return "the unpacked app is signed as \(identity.bundleIdentifier ?? "?") by team \(identity.teamIdentifier ?? "?")"
        }
        return nil
    }

    /// The security-scoped Applications folder, started: the persisted
    /// bookmark when there is one and it still resolves, else a one-time
    /// open panel preset to /Applications. nil when the user declined or
    /// picked another folder. The caller stops access.
    private func applicationsFolderAccess() -> URL? {
        if let data = defaults.data(forKey: Self.applicationsBookmarkKey) {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale),
               !stale,
               UpdateInstallPlan.isApplicationsFolder(url.path),
               url.startAccessingSecurityScopedResource() {
                return url
            }
            defaults.removeObject(forKey: Self.applicationsBookmarkKey)
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: UpdateInstallPlan.applicationsDirectory, isDirectory: true)
        panel.message = String(localized: "To install the update, allow URnetwork to replace itself in the Applications folder. Select Applications and click Allow.")
        panel.prompt = String(localized: "Allow")
        guard panel.runModal() == .OK, let url = panel.url,
              UpdateInstallPlan.isApplicationsFolder(url.path) else { return nil }
        if let data = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
            defaults.set(data, forKey: Self.applicationsBookmarkKey)
        }
        guard url.startAccessingSecurityScopedResource() else { return nil }
        return url
    }

    /// Trash (or park aside) the installed bundle, then move the verified
    /// one into its place. A failed second move puts the old bundle back.
    nonisolated static func replace(installed: URL, with candidate: URL, aside: URL) throws {
        let fileManager = FileManager.default
        var parked: URL
        do {
            var trashed: NSURL?
            try fileManager.trashItem(at: installed, resultingItemURL: &trashed)
            parked = (trashed as URL?) ?? aside
        } catch {
            try? fileManager.removeItem(at: aside)
            try fileManager.moveItem(at: installed, to: aside)
            parked = aside
        }
        do {
            try fileManager.moveItem(at: candidate, to: installed)
        } catch {
            try? fileManager.moveItem(at: parked, to: installed)
            throw error
        }
    }

    /// Best effort: aside copies a previous update left under /Applications
    /// (the Trash refused), removed by their exact grammar when the
    /// persisted bookmark still grants access. Nothing is asked of the user.
    private func cleanUpStaleAsideBundles() {
        guard let data = defaults.data(forKey: Self.applicationsBookmarkKey) else { return }
        var stale = false
        guard let folder = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale),
              !stale, UpdateInstallPlan.isApplicationsFolder(folder.path),
              folder.startAccessingSecurityScopedResource() else { return }
        defer { folder.stopAccessingSecurityScopedResource() }
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in entries where UpdateInstallPlan.isStaleAsideName(name) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    private func describe(_ error: Error) -> String {
        if let error = error as? CheckError { return error.message }
        return (error as NSError).localizedDescription
    }
}

/// The Settings copy for each phase, kept together so the row stays one
/// switch. Not repo-specific on purpose.
enum DirectUpdaterCopy {

    static func status(for phase: DirectUpdater.Phase) -> String {
        switch phase {
        case .idle:
            return String(localized: "Updates have not been checked yet.")
        case .checking:
            return String(localized: "Checking for updates…")
        case .upToDate:
            return String(localized: "URnetwork is up to date.")
        case .developmentBuild(let newest):
            return String(localized: "Development build; the newest release is \(newest.string).")
        case .available(let offer):
            return String(localized: "Update available: \(offer.version.string)")
        case .downloading(let offer):
            return String(localized: "Downloading \(offer.version.string)…")
        case .verifying:
            return String(localized: "Verifying the download…")
        case .installing:
            return String(localized: "Installing the update…")
        case .relaunching:
            return String(localized: "Relaunching URnetwork…")
        case .manualInstall(let offer, _):
            return String(localized: "\(offer.version.string) was downloaded and verified. Drag the new URnetwork into the Applications folder, then open it from there.")
        case .failed(_, let failure):
            return message(for: failure)
        }
    }

    static func message(for failure: DirectUpdater.Failure) -> String {
        switch failure {
        case .check(let detail):
            return String(localized: "Could not check for updates: \(detail)")
        case .unusableRelease(let newest, let reason):
            return String(localized: "Release \(newest.string) cannot be installed by the app (\(reason)).")
        case .download(let detail):
            return String(localized: "The download failed: \(detail)")
        case .checksum:
            return String(localized: "The download did not match the release checksum and was discarded.")
        case .unpack(let detail):
            return String(localized: "The download could not be unpacked: \(detail)")
        case .signature(let detail):
            return String(localized: "The update was rejected: \(detail)")
        case .access(let detail):
            return String(localized: "The update could not be installed: \(detail)")
        case .install(let detail):
            return String(localized: "The update could not be installed: \(detail)")
        }
    }

    enum Action: Equatable {
        case check
        case install
        case reveal

        var title: String {
            switch self {
            case .check: return String(localized: "Check for updates")
            case .install: return String(localized: "Install update")
            case .reveal: return String(localized: "Show in Finder")
            }
        }
    }

    /// The button next to the status, or nil while busy. A failed install
    /// retries the install from scratch (the offer is still known); a failed
    /// check offers another check.
    static func action(for phase: DirectUpdater.Phase) -> Action? {
        switch phase {
        case .available:
            return .install
        case .manualInstall:
            return .reveal
        case .failed(let offer, _):
            return offer == nil ? .check : .install
        case .idle, .upToDate, .developmentBuild:
            return .check
        case .checking, .downloading, .verifying, .installing, .relaunching:
            return nil
        }
    }
}

#endif
