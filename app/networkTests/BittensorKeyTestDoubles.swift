//
//  BittensorKeyTestDoubles.swift
//  networkTests
//
//  Stand-ins for the payout key's tests: a Keychain that holds items the way
//  the real one does, the SDK flow's seam, and the platform's calls. The flow's
//  own decisions are tested in the sdk (bittensor_local_key_flow_test.go); these
//  tests are for what this app does around them.
//

import Foundation
import Security
import URnetworkSdk
@testable import URnetwork

/// The Keychain's behaviour for generic passwords: an item is found by its
/// class, service, account and access group, an add never replaces, and a read
/// returns the data or the attributes it asks for.
final class FakeBittensorKeychain: BittensorKeychain, @unchecked Sendable {

    struct Item {
        var attributes: [String: Any]
        var data: Data
    }

    // the sdk calls in on its own goroutines, and a test reads at the same time
    private let stateLock = NSLock()
    private var storedItems: [Item] = []
    private var addCalls: [[String: Any]] = []
    private var readCalls: [[String: Any]] = []
    private var deleteCalls: [[String: Any]] = []
    private var failureStatus: OSStatus?

    var items: [Item] {
        stateLock.withLock { storedItems }
    }
    /// every dictionary passed in, to check what was asked for
    var adds: [[String: Any]] {
        stateLock.withLock { addCalls }
    }
    var reads: [[String: Any]] {
        stateLock.withLock { readCalls }
    }
    var deletes: [[String: Any]] {
        stateLock.withLock { deleteCalls }
    }
    /// the next calls answer this: errSecInteractionNotAllowed on a locked
    /// device, errSecMissingEntitlement on an unsigned build
    var failure: OSStatus? {
        get { stateLock.withLock { failureStatus } }
        set { stateLock.withLock { failureStatus = newValue } }
    }

    private func matches(_ item: Item, _ query: [String: Any]) -> Bool {
        for key in [kSecAttrService, kSecAttrAccount, kSecAttrAccessGroup] as [CFString] {
            guard let wanted = query[key as String] as? String else {
                continue
            }
            if item.attributes[key as String] as? String != wanted {
                return false
            }
        }
        return true
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        stateLock.withLock {
            addCalls.append(attributes)
            if let failureStatus {
                return failureStatus
            }
            if storedItems.contains(where: { matches($0, attributes) }) {
                return errSecDuplicateItem
            }
            var kept = attributes
            let data = attributes[kSecValueData as String] as? Data ?? Data()
            kept[kSecValueData as String] = nil
            storedItems.append(Item(attributes: kept, data: data))
            return errSecSuccess
        }
    }

    func copyMatching(_ query: [String: Any], result: inout CFTypeRef?) -> OSStatus {
        stateLock.lock()
        defer { stateLock.unlock() }
        readCalls.append(query)
        if let failureStatus {
            return failureStatus
        }
        guard let item = storedItems.first(where: { matches($0, query) }) else {
            return errSecItemNotFound
        }
        if query[kSecReturnData as String] as? Bool == true {
            result = item.data as CFData
        } else if query[kSecReturnAttributes as String] as? Bool == true {
            result = item.attributes as CFDictionary
        }
        return errSecSuccess
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        stateLock.withLock {
            deleteCalls.append(query)
            if let failureStatus {
                return failureStatus
            }
            let before = storedItems.count
            storedItems.removeAll { matches($0, query) }
            return storedItems.count == before ? errSecItemNotFound : errSecSuccess
        }
    }
}

/// The SDK flow's seam, recording what the model asks for and answering what a
/// test sets.
final class FakeBittensorKeyFlow: BittensorKeyFlowing {

    var card = BittensorKeyCardInfo()
    var screen = BittensorKeyScreenInfo()
    var revealedWords: [String] = []
    var phraseToCopy = ""
    var reminderAnswer = BittensorKeyReminderInfo()

    private(set) var calls: [String] = []
    private(set) var handler: (() -> Void)?

    func onChange(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    func reload() { calls.append("reload") }
    func setConsent(active: Bool, coldkeySs58: String, fromEpoch: Int64) { calls.append("setConsent(\(active), \(coldkeySs58), \(fromEpoch))") }
    func setConsentUnavailable() { calls.append("setConsentUnavailable") }
    func setCurrentEpoch(_ currentEpoch: Int64) { calls.append("setCurrentEpoch(\(currentEpoch))") }
    func setGuest(_ guest: Bool) { calls.append("setGuest(\(guest))") }
    func setTop200Registered(_ registered: Bool) { calls.append("setTop200Registered(\(registered))") }
    func setUpPayouts(replaceConfirmed: Bool) { calls.append("setUpPayouts(\(replaceConfirmed))") }
    func finishSetup(replaceConfirmed: Bool) { calls.append("finishSetup(\(replaceConfirmed))") }
    func saveFirst(replaceConfirmed: Bool) { calls.append("saveFirst(\(replaceConfirmed))") }
    func retrySaveNow() { calls.append("retrySaveNow") }
    func openScreen() { calls.append("openScreen") }
    func closeScreen() {
        calls.append("closeScreen")
        screen.open = false
        screen.done = false
    }
    func reveal(authenticated: Bool) { calls.append("reveal(\(authenticated))") }
    func hide() { calls.append("hide") }
    func setCaptureActive(_ active: Bool) { calls.append("setCaptureActive(\(active))") }
    var wordCheck = BittensorKeyWordCheckInfo()
    func confirmDelete() { calls.append("confirmDelete") }
    func confirmKeep() { calls.append("confirmKeep") }
    func cancelConfirmation() { calls.append("cancelConfirmation") }
    func checkWords(first: String, second: String) -> BittensorKeyWordCheckInfo { wordCheck }
    func submitWords(first: String, second: String, authenticated: Bool) { calls.append("submitWords(\(first), \(second), \(authenticated))") }
    func reminder(currentEpoch: Int64, claimOpenMillis: Int64, epochBlocks: Int64, claimable: Bool) -> BittensorKeyReminderInfo {
        calls.append("reminder(\(currentEpoch), \(claimOpenMillis), \(epochBlocks), \(claimable))")
        return reminderAnswer
    }
    func reminderScheduled(atMillis: Int64) { calls.append("reminderScheduled(\(atMillis))") }
    func reminderDelivered() { calls.append("reminderDelivered") }
    func fundsDisclaimer(at place: String) -> String {
        calls.append("fundsDisclaimer(\(place))")
        return SdkBittensorFundsDisclaimerNone
    }
    func close() { calls.append("close") }
}

final class FakeBittensorAuthenticator: BittensorDeviceAuthenticating {
    var answer = true
    private(set) var asked = 0

    func authenticate(reason: String) async -> Bool {
        asked += 1
        return answer
    }
}

final class FakeBittensorPasteboard: BittensorKeyPasteboarding {
    private(set) var copies: [String] = []

    func copy(_ phrase: String) {
        copies.append(phrase)
    }
}

final class FakeBittensorReminderPoster: BittensorKeyReminderPosting {
    private(set) var applied: [BittensorKeyReminderInfo] = []

    func apply(_ reminder: BittensorKeyReminderInfo, flow: BittensorKeyFlowing) {
        applied.append(reminder)
    }
}
