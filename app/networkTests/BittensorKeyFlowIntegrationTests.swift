//
//  BittensorKeyFlowIntegrationTests.swift
//  networkTests
//
//  The real SDK flow with this app's own store and adapter: a real key from the
//  sdk, an injected Keychain, and an api with no server, so the consent can only
//  fail and nothing goes on the network. The flow's rules are tested in the sdk
//  against a fake server; this shows the pieces fit, with the app's real seam.
//  The scan runs both flows and looks for the phrase everywhere it must not go.
//

import Foundation
import OSLog
import Security
import Testing
import URnetworkSdk
@testable import URnetwork

private let networkId = "01890000-0000-7000-8000-00000000000c"
private let testGroup = "TESTTEAM.network.ur.bittensor-key"

/// Waits for a state a goroutine reports. The bound only ends a failed test.
@MainActor
private func waitUntil(_ flow: SdkBittensorKeyFlow, _ done: () -> Bool) async {
    for _ in 0..<6000 {
        if done() {
            return
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    Issue.record("the flow never got there: \(flow.card), \(flow.screen)")
}

private final class Run {
    let keychain = FakeBittensorKeychain()
    let notes: UserDefaults
    let store: BittensorLocalKeyStore
    let flow: SdkBittensorKeyFlow
    let api: SdkApi
    private let directory: URL
    private let spaceManager: SdkNetworkSpaceManager

    init() throws {
        let suite = "network.ur.tests.bittensor-key-flow.\(UUID().uuidString)"
        notes = try #require(UserDefaults(suiteName: suite))
        notes.removePersistentDomain(forName: suite)
        store = BittensorLocalKeyStore(keychain: keychain, accessGroup: testGroup, notes: notes)

        // a real api that nothing answers: the consent fails, and nothing leaves the machine
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "bittensor-key-test-" + UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        spaceManager = try #require(SdkNewNetworkSpaceManager(directory.path))
        let values = SdkNetworkSpaceValues()
        values.apiUrl = "http://127.0.0.1:1"
        values.platformUrl = "ws://127.0.0.1:1"
        let key = try #require(SdkNewNetworkSpaceKey("bittensor-key.example", "test"))
        let space = try #require(spaceManager.updateNetworkSpaceValues(key, values: values))
        api = try #require(space.getApi())
        api.setByJwt("a-network-credential")
        flow = SdkBittensorKeyFlow(api: api, networkId: networkId, store: store)
    }

    deinit {
        flow.close()
        spaceManager.close()
        try? FileManager.default.removeItem(at: directory)
    }

    /// The words the check asks for, from the phrase.
    func askedWords(in phrase: String) -> (String, String) {
        let words = phrase.split(separator: " ").map(String.init)
        let screen = flow.screen
        return (words[screen.firstWordPosition - 1], words[screen.secondWordPosition - 1])
    }
}

@MainActor
@Suite(.serialized)
struct BittensorKeyFlowIntegrationTests {

    // Set up payouts on the real sdk: a key the sdk makes and accepts, written
    // through the store and read back; the consent fails with no server, the key
    // stays, and the card says Finish setup
    @discardableResult
    private func runSaveLater(_ run: Run) async -> String {
        run.flow.setConsent(active: false, coldkeySs58: "", fromEpoch: 0)
        #expect(run.flow.card.state == SdkBittensorLocalKeyStateNone)
        #expect(run.flow.card.offersSetUp)

        run.flow.setUpPayouts(replaceConfirmed: false)
        await waitUntil(run.flow) {
            run.flow.card.state == SdkBittensorLocalKeyStateSaveLaterNotLinked && !run.flow.card.busy
        }
        #expect(run.flow.card.offersFinishSetup)
        #expect(run.flow.card.backupReminder)
        #expect(!run.flow.card.failureCode.isEmpty)

        run.flow.openScreen()
        #expect(run.flow.screen.open && run.flow.screen.needsAuthentication && !run.flow.screen.revealed)
        #expect(run.flow.phraseToCopy.isEmpty)
        #expect(run.flow.revealedWords.isEmpty)

        run.flow.reveal(authenticated: false)
        #expect(!run.flow.screen.revealed)
        run.flow.reveal(authenticated: true)
        #expect(run.flow.screen.revealed)
        let words = run.flow.revealedWords
        #expect(words.count == 12)
        let phrase = run.flow.phraseToCopy
        #expect(phrase == words.joined(separator: " "))
        run.flow.hide()
        #expect(run.flow.phraseToCopy.isEmpty)

        // the item holds the phrase, and it opens the address the card names
        #expect(run.store.keyPhrase(networkId) == phrase)
        var error: NSError?
        let address = SdkBittensorLocalKeyAddress(phrase, &error)
        #expect(error == nil)
        #expect(SdkValidateSs58(address))
        #expect(run.store.keyAddress(networkId) == address)
        #expect(run.flow.card.storedAddress == address)
        #expect(run.store.needsBackup(networkId: networkId))
        return phrase
    }

    private func runDelete(_ run: Run, phrase: String) async {
        run.flow.confirmDelete()
        #expect(run.flow.screen.confirming == SdkBittensorLocalKeyConfirmDelete)
        #expect(run.flow.screen.confirmNeedsAuthentication)
        #expect(run.flow.screen.warnsTop200)

        run.flow.submitWords(first: "wrong", second: "words", authenticated: true)
        await waitUntil(run.flow) { run.flow.screen.wordsRejected }
        #expect(run.keychain.items.count == 1)

        let (first, second) = run.askedWords(in: phrase)
        #expect(run.flow.checkWords(first: first, second: second).ready)
        run.flow.submitWords(first: first, second: second, authenticated: true)
        // the item goes, a read shows it gone, and the card reads the store again
        await waitUntil(run.flow) { run.flow.card.state == SdkBittensorLocalKeyStateNone }
        #expect(run.keychain.items.isEmpty)
        run.flow.closeScreen()
        #expect(!run.store.needsBackup(networkId: networkId))
    }

    @Test func saveLaterStoresBeforeItSignsAndDeleteIsProved() async throws {
        let run = try Run()
        let phrase = await runSaveLater(run)
        await runDelete(run, phrase: phrase)
    }

    // a key the store still holds is found by the next flow, as after a crash or
    // a sign out, and only by its own network
    @Test func theNextFlowFindsTheKey() async throws {
        let run = try Run()
        let phrase = await runSaveLater(run)

        let next = SdkBittensorKeyFlow(api: run.api, networkId: networkId, store: run.store)
        next.setConsent(active: false, coldkeySs58: "", fromEpoch: 0)
        #expect(next.card.state == SdkBittensorLocalKeyStateSaveLaterNotLinked)
        #expect(next.card.storedAddress == run.flow.card.storedAddress)

        let other = SdkBittensorKeyFlow(api: run.api, networkId: "01890000-0000-7000-8000-00000000000d", store: run.store)
        other.setConsent(active: false, coldkeySs58: "", fromEpoch: 0)
        #expect(other.card.state == SdkBittensorLocalKeyStateNone)
        #expect(other.card.storedAddress.isEmpty)
        other.openScreen()
        other.reveal(authenticated: true)
        #expect(other.phraseToCopy.isEmpty)

        next.openScreen()
        next.reveal(authenticated: true)
        #expect(next.phraseToCopy == phrase)
        next.close()
        other.close()
    }

    // Save now on the real sdk: nothing reaches the Keychain, and leaving discards it
    @Test func saveNowNeverTouchesTheKeychain() async throws {
        let run = try Run()
        run.flow.setConsent(active: false, coldkeySs58: "", fromEpoch: 0)
        run.flow.saveFirst(replaceConfirmed: false)
        #expect(run.flow.card.state == SdkBittensorLocalKeyStateSaveNowShowing)
        #expect(run.flow.screen.saveNow && !run.flow.screen.needsAuthentication)

        run.flow.reveal(authenticated: false)
        let phrase = run.flow.phraseToCopy
        #expect(phrase.split(separator: " ").count == 12)
        run.flow.confirmDelete()
        let (first, second) = run.askedWords(in: phrase)
        run.flow.submitWords(first: first, second: second, authenticated: false)
        await waitUntil(run.flow) { run.flow.screen.offersRetry && !run.flow.screen.busy }
        #expect(run.flow.card.state == SdkBittensorLocalKeyStateSaveNowConsentFailed)
        // the flow looks for a stored address, and never reads or writes a secret
        #expect(run.keychain.adds.isEmpty)
        #expect(!run.keychain.reads.contains { $0[kSecReturnData as String] != nil })

        run.flow.closeScreen()
        #expect(run.flow.card.state == SdkBittensorLocalKeyStateNone)
        #expect(run.flow.phraseToCopy.isEmpty)
        #expect(run.keychain.adds.isEmpty)
    }

    // A run of both flows, with everything the app adds around them, then a
    // search for the phrase in what could keep it: stdout and stderr, the unified
    // log, preferences, the Keychain's attributes, the screen and card values, and
    // on iOS the app's own files. The model's Copy reaches only the pasteboard
    // stand-in, because the test taps it.
    @Test func thePhraseStaysOutOfLogsLocalStateAndPreferences() async throws {
        let started = Date()
        let capture = try StandardStreamCapture()
        let run = try Run()
        let pasteboard = FakeBittensorPasteboard()
        let model = BittensorKeyModel(
            flow: run.flow,
            authenticator: FakeBittensorAuthenticator(),
            pasteboard: pasteboard,
            reminderNotice: FakeBittensorReminderPoster()
        )

        let phrase = await runSaveLater(run)
        run.flow.openScreen()
        model.refresh()
        await model.tapToReveal()
        model.copy()
        #expect(pasteboard.copies == [phrase])
        var surfaces = ["\(model.card)", "\(model.screen)"]
        await runDelete(run, phrase: phrase)
        surfaces.append("\(model.card)")

        run.flow.saveFirst(replaceConfirmed: false)
        run.flow.reveal(authenticated: false)
        let saveNowPhrase = run.flow.phraseToCopy
        #expect(!saveNowPhrase.isEmpty && saveNowPhrase != phrase)
        surfaces.append("\(run.flow.card) \(run.flow.screen)")
        run.flow.closeScreen()

        let printed = try capture.finish()
        surfaces.append(printed)
        surfaces.append(try unifiedLog(since: started))
        surfaces.append("\(UserDefaults.standard.dictionaryRepresentation())")
        surfaces.append("\(run.notes.dictionaryRepresentation())")
        for add in run.keychain.adds {
            surfaces.append("\(add.filter { $0.key != kSecValueData as String })")
        }
        #if os(iOS)
        surfaces.append(contentsOf: appFilesChanged(since: started))
        #endif

        for secret in [phrase, saveNowPhrase] {
            let words = secret.split(separator: " ")
            #expect(words.count == 12)
            // a whole phrase, or any two of its words side by side; one word
            // alone can be an ordinary English word in a log line
            let pieces = [secret] + zip(words, words.dropFirst()).map { "\($0) \($1)" }
            for surface in surfaces {
                for piece in pieces where surface.contains(piece) {
                    Issue.record("the phrase reached a log, a file or a preference: \(piece.prefix(4))…")
                }
            }
        }
        withExtendedLifetime(model) {}
    }

    private func unifiedLog(since: Date) throws -> String {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let position = store.position(date: since)
        return try store.getEntries(at: position).map(\.composedMessage).joined(separator: "\n")
    }

    #if os(iOS)
    /// Everything in the app's container written since the run started.
    private func appFilesChanged(since: Date) -> [String] {
        var found: [String] = []
        let root = URL(fileURLWithPath: NSHomeDirectory())
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else {
            return found
        }
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate, since <= modified,
                  (values.fileSize ?? 0) < 8_000_000,
                  let data = try? Data(contentsOf: url) else {
                continue
            }
            found.append(String(decoding: data, as: UTF8.self))
        }
        return found
    }
    #endif
}

/// What the process writes to stdout and stderr while it is held.
private final class StandardStreamCapture {

    private let file: URL
    private let savedOut: Int32
    private let savedError: Int32
    private var finished = false

    init() throws {
        file = FileManager.default.temporaryDirectory.appendingPathComponent("bittensor-key-scan-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        fflush(stdout)
        fflush(stderr)
        savedOut = dup(STDOUT_FILENO)
        savedError = dup(STDERR_FILENO)
        let descriptor = open(file.path, O_WRONLY | O_APPEND)
        dup2(descriptor, STDOUT_FILENO)
        dup2(descriptor, STDERR_FILENO)
        close(descriptor)
    }

    func finish() throws -> String {
        finished = true
        fflush(stdout)
        fflush(stderr)
        dup2(savedOut, STDOUT_FILENO)
        dup2(savedError, STDERR_FILENO)
        close(savedOut)
        close(savedError)
        defer {
            try? FileManager.default.removeItem(at: file)
        }
        return try String(contentsOf: file, encoding: .utf8)
    }

    deinit {
        if !finished {
            _ = try? finish()
        }
    }
}
