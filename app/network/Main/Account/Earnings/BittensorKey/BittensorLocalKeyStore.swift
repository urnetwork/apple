//
//  BittensorLocalKeyStore.swift
//  URnetwork
//
//  The SDK's secret store for the payout key (sdk BittensorLocalKeyStore,
//  apple/BTEASY.md, Storage): one Keychain generic password per network id, in
//  a group only the app has, so the tunnel extension and the widgets can't read
//  it. It lives on this device: not in backups, not synced, not migrated. The
//  Keychain outlives a logout, and usually a reinstall, so the key comes back
//  when its network signs in again. Another network on the device asks for
//  another item and finds none.
//
//  The address is an attribute of the item, so the Earnings card can name the
//  key without reading the secret. The non-secret notes the SDK keeps by network
//  id (addresses and numbers, never a phrase) are preferences, which a logout
//  leaves alone too.
//
//  This file holds no decisions: the SDK reads back what it writes before it
//  signs, and checks a deletion by reading again. It never logs: a Keychain
//  status is all a failure says, and nothing here prints even that.
//

import Foundation
import Security
import URnetworkSdk

/// The Keychain calls the store makes, so a test can stand in where the real
/// one isn't available (an unsigned build has no keychain entitlement).
protocol BittensorKeychain {
    func add(_ attributes: [String: Any]) -> OSStatus
    func copyMatching(_ query: [String: Any], result: inout CFTypeRef?) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}

struct SystemBittensorKeychain: BittensorKeychain {

    func add(_ attributes: [String: Any]) -> OSStatus {
        SecItemAdd(attributes as CFDictionary, nil)
    }

    func copyMatching(_ query: [String: Any], result: inout CFTypeRef?) -> OSStatus {
        SecItemCopyMatching(query as CFDictionary, &result)
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }
}

final class BittensorLocalKeyStore: NSObject, SdkBittensorLocalKeyStoreProtocol {

    static let shared = BittensorLocalKeyStore()

    static let keychainService = "network.ur.bittensor-local-key"
    /// the Info.plist key of the group (URnetwork-Info.plist), which both Mac
    /// builds name the same, so they see the same key
    static let accessGroupInfoKey = "URBittensorKeyKeychainAccessGroup"
    private static let notePrefix = "network.ur.bittensor-local-key."

    private let keychain: BittensorKeychain
    private let accessGroup: String?
    private let notes: UserDefaults

    init(
        keychain: BittensorKeychain = SystemBittensorKeychain(),
        accessGroup: String? = BittensorLocalKeyStore.bundleAccessGroup(),
        notes: UserDefaults = .standard
    ) {
        self.keychain = keychain
        self.accessGroup = accessGroup
        self.notes = notes
    }

    /// The group as this build's settings name it, or nil for none. With no
    /// group an add would land in the entitlements' first one, which the tunnel
    /// extension shares, so the store then refuses instead.
    static func bundleAccessGroup(_ bundle: Bundle = .main) -> String? {
        guard let accessGroup = bundle.object(forInfoDictionaryKey: accessGroupInfoKey) as? String,
              !accessGroup.isEmpty,
              !accessGroup.contains("$(") else {
            return nil
        }
        return accessGroup
    }

    /// What finds the network's item, and only that: the data protection
    /// keychain on macOS (on iOS it is the only one), and never a synced item.
    private func identity(_ networkId: String) -> [String: Any]? {
        guard let accessGroup, !accessGroup.isEmpty, !networkId.isEmpty else {
            return nil
        }
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: networkId,
            kSecAttrAccessGroup as String: accessGroup,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: false,
        ]
    }

    // MARK: SdkBittensorLocalKeyStoreProtocol

    func addKey(_ networkId: String?, mnemonic: String?, address: String?) -> Bool {
        guard let networkId, let mnemonic, let address, !mnemonic.isEmpty, !address.isEmpty,
              var attributes = identity(networkId) else {
            return false
        }
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        attributes[kSecAttrGeneric as String] = Data(address.utf8)
        attributes[kSecValueData as String] = Data(mnemonic.utf8)
        // an add never replaces: errSecDuplicateItem is a refusal
        return keychain.add(attributes) == errSecSuccess
    }

    func keyPhrase(_ networkId: String?) -> String {
        guard let networkId, var query = identity(networkId) else {
            return SdkBittensorLocalKeyStoreUnavailable
        }
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        switch keychain.copyMatching(query, result: &result) {
        case errSecSuccess:
            guard let data = result as? Data, let phrase = String(data: data, encoding: .utf8) else {
                return SdkBittensorLocalKeyStoreUnavailable
            }
            return phrase
        case errSecItemNotFound:
            return ""
        default:
            return SdkBittensorLocalKeyStoreUnavailable
        }
    }

    func keyAddress(_ networkId: String?) -> String {
        guard let networkId, var query = identity(networkId) else {
            return SdkBittensorLocalKeyStoreUnavailable
        }
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        switch keychain.copyMatching(query, result: &result) {
        case errSecSuccess:
            guard let attributes = result as? [String: Any],
                  let data = attributes[kSecAttrGeneric as String] as? Data,
                  let address = String(data: data, encoding: .utf8) else {
                return SdkBittensorLocalKeyStoreUnavailable
            }
            return address
        case errSecItemNotFound:
            return ""
        default:
            return SdkBittensorLocalKeyStoreUnavailable
        }
    }

    func deleteKey(_ networkId: String?) -> Bool {
        guard let networkId, let query = identity(networkId) else {
            return false
        }
        switch keychain.delete(query) {
        case errSecSuccess, errSecItemNotFound:
            return true
        default:
            return false
        }
    }

    func readNote(_ networkId: String?, name: String?) -> String {
        notes.string(forKey: Self.noteKey(networkId, name)) ?? ""
    }

    func writeNote(_ networkId: String?, name: String?, value: String?) {
        let key = Self.noteKey(networkId, name)
        if let value, !value.isEmpty {
            notes.set(value, forKey: key)
        } else {
            notes.removeObject(forKey: key)
        }
    }

    private static func noteKey(_ networkId: String?, _ name: String?) -> String {
        notePrefix + (networkId ?? "") + "." + (name ?? "")
    }

    // MARK: outside the Earnings screen

    /// The network has a key here whose phrase is not known to be saved: the
    /// sign out and account deletion confirmations warn.
    func needsBackup(networkId: String?) -> Bool {
        guard let networkId, !networkId.isEmpty, let flow = SdkNewBittensorLocalKeyFlow(nil, networkId, self) else {
            return false
        }
        defer {
            flow.close()
        }
        return flow.needsBackup()
    }

    /// Removes the key and the notes after an account deletion.
    @discardableResult
    func forgetNetwork(networkId: String?) -> Bool {
        guard let networkId, !networkId.isEmpty, let flow = SdkNewBittensorLocalKeyFlow(nil, networkId, self) else {
            return false
        }
        defer {
            flow.close()
        }
        return flow.forgetNetwork()
    }
}
