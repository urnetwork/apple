//
//  BittensorLocalKeyStoreTests.swift
//  networkTests
//
//  The payout key's Keychain store (apple/BTEASY.md, Storage and Tests): written
//  and read back, one item per network, gone once deleted, still there after a
//  logout. An injected Keychain stands in where the real one isn't available
//  (an unsigned build has no entitlement). The item's attributes are checked as
//  the store passes them, since those are what make it device-only.
//

import Foundation
import Security
import Testing
import URnetworkSdk
@testable import URnetwork

// published test data from sdk bittensor_local_key_test.go: never funded
private let testPhrase = "hotel forest jar hover kite book view eight stuff angle legend defense"
private let testAddress = "5Hpm9fq3W3dQgwWpAwDS2ZHKAdnk86QRCu7iX4GnmDxycrte"
private let networkA = "01890000-0000-7000-8000-00000000000a"
private let networkB = "01890000-0000-7000-8000-00000000000b"
private let testGroup = "TESTTEAM.network.ur.bittensor-key"

private func freshDefaults() -> UserDefaults {
    let suite = "network.ur.tests.bittensor-key.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
}

struct BittensorLocalKeyStoreTests {

    private func makeStore(_ keychain: FakeBittensorKeychain = FakeBittensorKeychain(), notes: UserDefaults = freshDefaults()) -> BittensorLocalKeyStore {
        BittensorLocalKeyStore(keychain: keychain, accessGroup: testGroup, notes: notes)
    }

    // the item is device-only, in the data protection keychain, in the group
    // only the app has, and not synced
    @Test func theItemIsOnThisDeviceOnly() throws {
        let keychain = FakeBittensorKeychain()
        #expect(makeStore(keychain).addKey(networkA, mnemonic: testPhrase, address: testAddress))
        let added = try #require(keychain.adds.first)
        #expect(added[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(added[kSecAttrService as String] as? String == BittensorLocalKeyStore.keychainService)
        #expect(added[kSecAttrAccount as String] as? String == networkA)
        #expect(added[kSecAttrAccessGroup as String] as? String == testGroup)
        #expect(added[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        #expect(added[kSecUseDataProtectionKeychain as String] as? Bool == true)
        #expect(added[kSecAttrSynchronizable as String] as? Bool == false)
        #expect(added[kSecValueData as String] as? Data == Data(testPhrase.utf8))
        #expect(added[kSecAttrGeneric as String] as? Data == Data(testAddress.utf8))
        // every read and delete looks in the same place
        _ = makeStore(keychain).keyPhrase(networkA)
        _ = makeStore(keychain).deleteKey(networkA)
        for query in keychain.reads + keychain.deletes {
            #expect(query[kSecAttrAccessGroup as String] as? String == testGroup)
            #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == true)
            #expect(query[kSecAttrSynchronizable as String] as? Bool == false)
        }
    }

    @Test func whatIsWrittenReadsBack() {
        let store = makeStore()
        #expect(store.keyPhrase(networkA).isEmpty)
        #expect(store.keyAddress(networkA).isEmpty)
        #expect(store.addKey(networkA, mnemonic: testPhrase, address: testAddress))
        #expect(store.keyPhrase(networkA) == testPhrase)
        #expect(store.keyAddress(networkA) == testAddress)
    }

    // the card names the key without the secret coming out of the Keychain
    @Test func theAddressReadsWithoutTheSecret() throws {
        let keychain = FakeBittensorKeychain()
        let store = makeStore(keychain)
        #expect(store.addKey(networkA, mnemonic: testPhrase, address: testAddress))
        #expect(store.keyAddress(networkA) == testAddress)
        let read = try #require(keychain.reads.last)
        #expect(read[kSecReturnData as String] == nil)
        #expect(read[kSecReturnAttributes as String] as? Bool == true)
    }

    // one key per network: an add never replaces the phrase that holds the
    // earlier earnings
    @Test func anAddNeverReplacesAnItem() {
        let keychain = FakeBittensorKeychain()
        let store = makeStore(keychain)
        #expect(store.addKey(networkA, mnemonic: testPhrase, address: testAddress))
        #expect(!store.addKey(networkA, mnemonic: "another phrase", address: "5Another"))
        #expect(store.keyPhrase(networkA) == testPhrase)
        #expect(store.keyAddress(networkA) == testAddress)
        #expect(keychain.items.count == 1)
    }

    @Test func eachNetworkHasItsOwnItem() {
        let store = makeStore()
        #expect(store.addKey(networkA, mnemonic: testPhrase, address: testAddress))
        #expect(store.keyPhrase(networkB).isEmpty)
        #expect(store.keyAddress(networkB).isEmpty)
        #expect(store.addKey(networkB, mnemonic: "another phrase", address: "5Another"))
        #expect(store.keyPhrase(networkA) == testPhrase)
        #expect(store.keyPhrase(networkB) == "another phrase")
        #expect(store.deleteKey(networkB))
        #expect(store.keyPhrase(networkA) == testPhrase)
        #expect(store.keyPhrase(networkB).isEmpty)
    }

    @Test func aDeletedKeyIsGone() {
        let keychain = FakeBittensorKeychain()
        let store = makeStore(keychain)
        #expect(store.addKey(networkA, mnemonic: testPhrase, address: testAddress))
        #expect(store.deleteKey(networkA))
        #expect(store.keyPhrase(networkA).isEmpty)
        #expect(store.keyAddress(networkA).isEmpty)
        #expect(keychain.items.isEmpty)
        // nothing there is not a refusal
        #expect(store.deleteKey(networkA))
    }

    // a locked device or a refused call reads as "can't say", never as "no
    // key": the SDK then offers nothing that would make a second one
    @Test func aRefusedKeychainReadsAsUnavailable() {
        let keychain = FakeBittensorKeychain()
        let store = makeStore(keychain)
        #expect(store.addKey(networkA, mnemonic: testPhrase, address: testAddress))
        for failure in [errSecInteractionNotAllowed, errSecMissingEntitlement, errSecAuthFailed] {
            keychain.failure = failure
            #expect(store.keyPhrase(networkA) == SdkBittensorLocalKeyStoreUnavailable)
            #expect(store.keyAddress(networkA) == SdkBittensorLocalKeyStoreUnavailable)
            #expect(!store.addKey(networkB, mnemonic: testPhrase, address: testAddress))
            #expect(!store.deleteKey(networkA))
        }
    }

    // with no group of its own an add would land in the entitlements' first
    // group, which the tunnel extension shares, so the store refuses
    @Test func noGroupMeansNoKey() {
        let keychain = FakeBittensorKeychain()
        let store = BittensorLocalKeyStore(keychain: keychain, accessGroup: nil, notes: freshDefaults())
        #expect(!store.addKey(networkA, mnemonic: testPhrase, address: testAddress))
        #expect(store.keyPhrase(networkA) == SdkBittensorLocalKeyStoreUnavailable)
        #expect(store.keyAddress(networkA) == SdkBittensorLocalKeyStoreUnavailable)
        #expect(!store.deleteKey(networkA))
        #expect(keychain.adds.isEmpty && keychain.reads.isEmpty && keychain.deletes.isEmpty)

        // a setting that did not expand is no group either
        let empty = BittensorLocalKeyStore(keychain: keychain, accessGroup: "", notes: freshDefaults())
        #expect(!empty.addKey(networkA, mnemonic: testPhrase, address: testAddress))
    }

    // a sign out clears the SDK's local state and the tunnel credential, and
    // the item stays: a new store on the same Keychain finds it by network id
    @Test func theKeySurvivesASignOut() {
        let keychain = FakeBittensorKeychain()
        let notes = freshDefaults()
        let before = makeStore(keychain, notes: notes)
        #expect(before.addKey(networkA, mnemonic: testPhrase, address: testAddress))
        before.writeNote(networkA, name: "saved_address", value: testAddress)

        let after = makeStore(keychain, notes: notes)
        #expect(after.keyPhrase(networkA) == testPhrase)
        #expect(after.keyAddress(networkA) == testAddress)
        #expect(after.readNote(networkA, name: "saved_address") == testAddress)
        #expect(after.keyPhrase(networkB).isEmpty)
    }

    @Test func notesAreKeptByNetworkAndNeverHoldTheSecret() {
        let notes = freshDefaults()
        let store = makeStore(notes: notes)
        #expect(store.readNote(networkA, name: "deleted_address").isEmpty)
        store.writeNote(networkA, name: "deleted_address", value: testAddress)
        #expect(store.readNote(networkA, name: "deleted_address") == testAddress)
        #expect(store.readNote(networkB, name: "deleted_address").isEmpty)
        store.writeNote(networkA, name: "deleted_address", value: "")
        #expect(store.readNote(networkA, name: "deleted_address").isEmpty)

        #expect(store.addKey(networkA, mnemonic: testPhrase, address: testAddress))
        let everything = notes.dictionaryRepresentation().description
        #expect(!everything.contains(testPhrase))
        for word in testPhrase.split(separator: " ") {
            #expect(!everything.contains(" \(word) "))
        }
    }

    // the warning at sign out and account deletion, and the deletion, through
    // the SDK's own decisions
    @Test func theSdkDecidesTheWarningAndForgetting() {
        let keychain = FakeBittensorKeychain()
        let store = makeStore(keychain)
        #expect(!store.needsBackup(networkId: networkA))
        #expect(!store.needsBackup(networkId: nil))
        #expect(store.addKey(networkA, mnemonic: testPhrase, address: testAddress))
        #expect(store.needsBackup(networkId: networkA))
        #expect(!store.needsBackup(networkId: networkB))

        store.writeNote(networkA, name: "deleted_address", value: testAddress)
        #expect(store.forgetNetwork(networkId: networkA))
        #expect(keychain.items.isEmpty)
        #expect(store.readNote(networkA, name: "deleted_address").isEmpty)
        #expect(!store.needsBackup(networkId: networkA))
    }

    // the group this build names, from the settings both app targets carry;
    // the first entitlement stays the tunnel's, so nothing else moved
    @Test func theBuildNamesTheGroup() throws {
        let group = try #require(BittensorLocalKeyStore.bundleAccessGroup())
        #expect(group.hasSuffix("network.ur.bittensor-key"))
    }

    // The real Keychain, where this run has one: an unsigned build has no
    // entitlement and says so, which is what the injected Keychain is for.
    @Test func theSystemKeychainRoundTrip() throws {
        let network = "01890000-0000-7000-8000-\(UUID().uuidString.suffix(12).lowercased())"
        let group = try #require(BittensorLocalKeyStore.bundleAccessGroup())
        let store = BittensorLocalKeyStore(keychain: SystemBittensorKeychain(), accessGroup: group, notes: freshDefaults())
        guard store.keyAddress(network) != SdkBittensorLocalKeyStoreUnavailable else {
            print("[BittensorLocalKeyStoreTests]this run has no real Keychain: the round trip did not run")
            return
        }
        print("[BittensorLocalKeyStoreTests]the round trip is on the real Keychain, group \(group)")
        defer {
            _ = store.deleteKey(network)
        }
        #expect(store.keyPhrase(network).isEmpty)
        #expect(store.addKey(network, mnemonic: testPhrase, address: testAddress))
        #expect(store.keyPhrase(network) == testPhrase)
        #expect(store.keyAddress(network) == testAddress)
        #expect(!store.addKey(network, mnemonic: "another phrase", address: "5Another"))
        #expect(store.deleteKey(network))
        #expect(store.keyPhrase(network).isEmpty)
        #expect(store.keyAddress(network).isEmpty)
    }
}
