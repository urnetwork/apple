//
//  ExtenderSettingsStore.swift
//  URnetwork
//

import Foundation
import SwiftUI
import URnetworkSdk

/**
 * The extender settings, share and import of the active network space
 * (EXTENDER.md K6, K7).
 *
 * Everything that decides anything — encoding, decoding, applying, what the
 * defaults are — lives in the sdk's `ExtenderViewController`, one
 * implementation for every app. This store owns that controller's lifetime,
 * maps its values onto plain Swift values the account screens bind to, and
 * carries the one thing the controller does not: the legacy single private
 * extender, which is a network space value edited through the space manager.
 */

// MARK: - values

/// What the settings form edits. An empty field means the derived default, so
/// clearing a box is how a user goes back to it (K6).
struct ExtenderSettingsFields: Equatable {
    var dnsName: String = ""
    var gossipUrl: String = ""
    /// one host per line
    var hostsText: String = ""
}

/// What the form shows but does not edit: the defaults behind the empty
/// fields, and the network this space keys its extenders by.
struct ExtenderSettingsPlaceholders: Equatable {
    /// the effective extender dns name
    var dnsName: String = ""
    /// the effective gossip url
    var gossipUrl: String = ""
    /// the operator host a share names and an import is judged against
    var networkHost: String = ""

    static let empty = ExtenderSettingsPlaceholders()
}

/// The legacy single private extender with its secret, which overrides every
/// discovered extender while it is set (K6, advanced).
struct PrivateExtenderFields: Equatable {
    var ip: String = ""
    var secret: String = ""

    var isEmpty: Bool {
        ip.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// The manual bootstrap hosts of a hosts field: one per line, trimmed, blank
/// lines dropped. The sdk trims too, but the form must show the user exactly
/// the list that will be stored.
func extenderSettingsHosts(_ hostsText: String) -> [String] {
    hostsText
        .split(whereSeparator: { $0.isNewline })
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
}

/// The hosts field text of a stored list.
func extenderSettingsHostsText(_ hosts: [String]) -> String {
    hosts.joined(separator: "\n")
}

// MARK: - share and import

/// A built share payload (K7).
struct ExtenderShare: Equatable {
    let text: String
    let count: Int
    let includesSettings: Bool

    static let empty = ExtenderShare(text: "", count: 0, includesSettings: false)

    var isEmpty: Bool { text.isEmpty }
}

/// What a scanned, chosen or pasted payload turns out to be — the decision the
/// import screen renders before anything is applied (K7).
enum ExtenderImportDecision: Equatable {
    /// not an extender share at all, or one this build cannot read
    case invalid
    /// another operator's network, and no settings block to switch to it with:
    /// its addresses could never be verified here, so the import is refused
    case foreignWithoutSettings(networkHost: String)
    /// a payload that can be imported. `requiresSettings` is a foreign network
    /// whose addresses come only together with its settings.
    case ready(count: Int, hasSettings: Bool, settingsHost: String, requiresSettings: Bool)
}

/// The decision for one decoded payload. Split from the sdk result so the
/// import screen's rules are exercised without a device.
func extenderImportDecision(
    ok: Bool,
    error: String,
    networkHost: String,
    foreignHost: Bool,
    count: Int,
    hasSettings: Bool,
    settingsHost: String
) -> ExtenderImportDecision {
    guard ok, error.isEmpty else {
        return .invalid
    }
    if foreignHost && !hasSettings {
        // the sdk refuses this import; say so before the user tries
        return .foreignWithoutSettings(networkHost: networkHost)
    }
    return .ready(
        count: count,
        hasSettings: hasSettings,
        settingsHost: settingsHost,
        requiresSettings: foreignHost
    )
}

func extenderImportDecision(_ result: SdkExtenderShareDecodeResult) -> ExtenderImportDecision {
    extenderImportDecision(
        ok: result.ok,
        error: result.error,
        networkHost: result.networkHost,
        foreignHost: result.foreignHost,
        count: result.count,
        hasSettings: result.hasSettings,
        settingsHost: result.settingsHost
    )
}

/// Whether the import action may run at all. A foreign network's payload is
/// taken only together with its settings.
func extenderImportAllowed(_ decision: ExtenderImportDecision, useSettings: Bool) -> Bool {
    switch decision {
    case .invalid, .foreignWithoutSettings:
        return false
    case .ready(_, _, _, let requiresSettings):
        return useSettings || !requiresSettings
    }
}

/// Whether the import must be confirmed first: taking a payload's settings
/// replaces this space's dns name, gossip url and trust anchor, which is the
/// one destructive thing an import can do (K7).
func extenderImportNeedsConfirmation(_ decision: ExtenderImportDecision, useSettings: Bool) -> Bool {
    guard useSettings else {
        return false
    }
    switch decision {
    case .invalid, .foreignWithoutSettings:
        return false
    case .ready(_, let hasSettings, _, _):
        return hasSettings
    }
}

/// The result of applying a payload.
enum ExtenderImportOutcome: Equatable {
    case imported(count: Int)
    case failed(error: String)
}

// MARK: - store

private class ExtenderNetworkSpaceUpdateCallback: NSObject, SdkNetworkSpaceUpdateProtocol {
    private let c: (SdkNetworkSpaceValues) -> Void

    init(c: @escaping (SdkNetworkSpaceValues) -> Void) {
        self.c = c
    }

    func update(_ values: SdkNetworkSpaceValues?) {
        if let values {
            c(values)
        }
    }
}

@MainActor
class ExtenderSettingsStore: ObservableObject {

    /// the editable values, bound by the form
    @Published var fields: ExtenderSettingsFields = ExtenderSettingsFields()
    /// the defaults behind the empty fields
    @Published private(set) var placeholders: ExtenderSettingsPlaceholders = .empty
    /// the legacy private extender, bound by the advanced section
    @Published var privateExtender: PrivateExtenderFields = PrivateExtenderFields()
    /// true once the sdk settings have been read, so the form does not save a
    /// blank over a stored value while it is still loading
    @Published private(set) var loaded: Bool = false

    private var device: SdkDeviceRemote?
    private weak var deviceManager: DeviceManager?
    private var viewController: SdkExtenderViewController?

    func setup(_ deviceManager: DeviceManager) {
        reset()

        self.deviceManager = deviceManager
        guard let device = deviceManager.device else {
            return
        }
        self.device = device
        let vc = device.openExtenderViewController()
        self.viewController = vc
        vc?.start()
        load()
    }

    func reset() {
        if let viewController {
            viewController.stop()
            if let device {
                device.close(viewController)
            } else {
                viewController.close()
            }
        }
        viewController = nil
        device = nil
        deviceManager = nil
        fields = ExtenderSettingsFields()
        placeholders = .empty
        privateExtender = PrivateExtenderFields()
        loaded = false
    }

    private func load() {
        guard let settings = viewController?.getSettings() else {
            return
        }
        apply(settings)
        loadPrivateExtender()
        loaded = true
    }

    private func apply(_ settings: SdkExtenderSettings) {
        var hosts: [String] = []
        if let list = settings.hosts {
            for i in 0..<list.len() {
                hosts.append(list.get(i))
            }
        }
        // a field the space derives is shown empty with the derived value as
        // its placeholder; a configured one is shown as it is stored
        fields = ExtenderSettingsFields(
            dnsName: settings.dnsNameDefault ? "" : settings.dnsName,
            gossipUrl: settings.gossipUrlDefault ? "" : settings.gossipUrl,
            hostsText: extenderSettingsHostsText(hosts)
        )
        // the sdk reports the value in force, not the derivation behind an
        // override, so an overridden field's placeholder names what is in force
        // until the field is cleared and saved -- at which point the sdk
        // answers with the real default
        placeholders = ExtenderSettingsPlaceholders(
            dnsName: settings.dnsName,
            gossipUrl: settings.gossipUrl,
            networkHost: settings.networkHost
        )
    }

    private func loadPrivateExtender() {
        guard let netExtender = deviceManager?.networkSpace?.getNetExtender() else {
            privateExtender = PrivateExtenderFields()
            return
        }
        privateExtender = PrivateExtenderFields(ip: netExtender.ip, secret: netExtender.secret)
    }

    /// Saves the three edited values and the private extender. The space's
    /// network client and node restart in place; on iOS the tunnel extension
    /// picks the values up at its next start.
    func save() {
        guard let viewController else {
            return
        }
        let hosts = SdkNewStringList()
        for host in extenderSettingsHosts(fields.hostsText) {
            hosts?.add(host)
        }
        let settings = viewController.setSettings(
            fields.dnsName,
            gossipUrl: fields.gossipUrl,
            hosts: hosts
        )
        savePrivateExtender()
        if let settings {
            apply(settings)
        }
        loadPrivateExtender()
    }

    /// The legacy private extender is a network space value, not one of the
    /// controller's three. An extender-only value change is applied in place by
    /// the space manager, so the running device and this controller stay valid.
    private func savePrivateExtender() {
        guard let deviceManager,
              let networkSpaceManager = deviceManager.networkSpaceManager,
              let key = deviceManager.networkSpace?.getKey() else {
            return
        }
        let ip = privateExtender.ip.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = privateExtender.secret.trimmingCharacters(in: .whitespacesAndNewlines)
        let stored = deviceManager.networkSpace?.getNetExtender()
        // an unchanged private extender is not written at all: every write is a
        // new space generation
        if (stored?.ip ?? "") == ip && (stored?.secret ?? "") == secret {
            return
        }
        let updated = networkSpaceManager.updateNetworkSpace(key, callback: ExtenderNetworkSpaceUpdateCallback(
            c: { values in
                if ip.isEmpty {
                    values.netExtender = nil
                } else {
                    let netExtender = SdkNetExtender()
                    netExtender.ip = ip
                    netExtender.secret = secret
                    values.netExtender = netExtender
                }
            }
        ))
        if let updated {
            deviceManager.setActiveNetworkSpace(updated)
        }
    }

    // MARK: share and import

    func buildShare(includeSettings: Bool) -> ExtenderShare {
        guard let result = viewController?.buildShare(includeSettings) else {
            return .empty
        }
        return ExtenderShare(
            text: result.text,
            count: result.count,
            includesSettings: result.includesSettings
        )
    }

    func decodeShare(_ text: String) -> ExtenderImportDecision {
        guard let result = viewController?.decodeShare(text) else {
            return .invalid
        }
        return extenderImportDecision(result)
    }

    func importShare(_ text: String, useSettings: Bool) -> ExtenderImportOutcome {
        guard let result = viewController?.importShare(text, useSettings: useSettings) else {
            return .failed(error: SdkExtenderImportErrorInvalid)
        }
        guard result.ok else {
            return .failed(error: result.error)
        }
        // the settings may have changed under us
        load()
        return .imported(count: result.importedCount)
    }
}
