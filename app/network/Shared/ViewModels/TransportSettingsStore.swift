//
//  TransportSettingsStore.swift
//  URnetwork
//

import Foundation
import SwiftUI
import URnetworkSdk

/**
 * The stable transport vocabulary shared with the SDK. The raw values are the
 * SDK `TransportType` strings, which double as the `TransportMode` strings for
 * the selectable carriers. p2p and unknown are observable carriers only: p2p
 * is negotiated per peer outside the transport policy, and unknown holds
 * traffic admitted for sending that has not yet been written to a physical
 * carrier (it is attributed to its carrier on the first route write).
 *
 * Only presentation lives here (names, colors, descriptions). Every rule --
 * the stable order, the selectable modes and their default preference order,
 * which carriers a policy enables, and the Auto editing constraints -- is the
 * SDK's, so it is shared and tested once for every platform.
 */
enum TransportType: String, CaseIterable, Identifiable, Hashable {
    case h3 = "h3"
    case h1 = "h1"
    /// tunneled over DNS -- the "whodis" transport
    case dns = "dns"
    /// tunneled over DNS with a constant-rate reply pump -- "whodis pump"
    case dnsPump = "dnspump"
    case p2p = "p2p"
    /// admitted but not yet attributed to a physical carrier (queued)
    case unknown = "unknown"

    var id: String { rawValue }

    /**
     * The carriers a transport mode can select, in the SDK's default preference
     * order (h3 and h1 tie as the direct tier, then dns, then dns pump). This
     * is the order every transport list in the app shows them in.
     */
    static var selectable: [TransportType] {
        Self.fromSdk(SdkSelectableTransportModes())
    }

    var isSelectable: Bool {
        Self.selectable.contains(self)
    }

    /**
     * maps an sdk string list of transport types / modes, dropping unknown
     * vocabulary
     */
    static func fromSdk(_ list: SdkStringList?) -> [TransportType] {
        guard let list else {
            return []
        }
        var types: [TransportType] = []
        types.reserveCapacity(list.len())
        for i in 0..<list.len() {
            if let type = TransportType(rawValue: list.get(i)) {
                types.append(type)
            }
        }
        return types
    }

    /**
     * The display name. The DNS carriers carry their product names, which are
     * not localized; the queued bucket is a plain word and is.
     */
    var label: Text {
        switch self {
        case .h3: return Text(verbatim: "H3")
        case .h1: return Text(verbatim: "H1")
        case .dns: return Text(verbatim: "whodis")
        case .dnsPump: return Text(verbatim: "whodis pump")
        case .p2p: return Text(verbatim: "P2P")
        case .unknown: return Text("queued")
        }
    }

    /**
     * A one line description for the settings editor
     */
    var detail: LocalizedStringKey? {
        switch self {
        case .h3: return "Direct over QUIC. Fastest where it is not filtered."
        case .h1: return "Direct over TLS. Works on most networks."
        case .dns: return "Disguised as DNS traffic. For networks that filter direct connections."
        case .dnsPump: return "Disguised as DNS traffic with a constant reply pump. Lowest bandwidth, highest availability."
        case .p2p: return nil
        case .unknown: return nil
        }
    }

    /**
     * The brand color of the carrier, used for the transport bar segments and
     * the legend dots. The queued bucket is neutral.
     */
    func color(_ theme: Theme) -> Color {
        switch self {
        case .h3: return .urGreen
        case .h1: return .urLightBlue
        case .dns: return .urPink
        case .dnsPump: return .urYellow
        case .p2p: return .urElectricBlue
        case .unknown: return theme.textMutedColor
        }
    }
}

/**
 * A render snapshot of an SDK transport policy: one carrier, or auto over the
 * enabled carriers. Derived entirely through the SDK helpers so the app never
 * re-implements the policy rules; edits go through the SDK object (`sdk`),
 * then a fresh snapshot is taken.
 */
struct TransportSettings: Equatable {

    /**
     * the selected carrier, or nil for auto
     */
    let singleTransport: TransportType?

    /**
     * the carriers enabled under auto in the SDK's preference order. Retained
     * while a single carrier is selected, so switching back to auto restores
     * the same policy
     */
    let autoTransports: [TransportType]

    /**
     * the carriers the policy enables, in preference order: the single
     * carrier, or the auto carriers
     */
    let enabledTransports: [TransportType]

    /**
     * the SDK policy this snapshot was taken from. Clone it to edit.
     */
    let sdk: SdkTransportSettings

    var isAuto: Bool {
        singleTransport == nil
    }

    func isAutoEnabled(_ transport: TransportType) -> Bool {
        autoTransports.contains(transport)
    }

    init(_ sdk: SdkTransportSettings) {
        self.sdk = sdk
        if sdk.mode == SdkTransportModeAuto {
            singleTransport = nil
        } else if let transport = TransportType(rawValue: sdk.mode), transport.isSelectable {
            singleTransport = transport
        } else {
            // an unrecognized mode normalizes to auto in the sdk
            singleTransport = nil
        }
        autoTransports = TransportType.fromSdk(sdk.autoModes())
        enabledTransports = TransportType.fromSdk(sdk.enabledTransportTypes())
    }

    /**
     * the SDK default client policy: auto over every carrier
     */
    static var defaultClient: TransportSettings {
        TransportSettings(SdkDefaultTransportSettings() ?? SdkTransportSettings())
    }

    /**
     * the SDK default provider policy
     */
    static var defaultProvider: TransportSettings {
        TransportSettings(SdkDefaultProviderTransportSettings() ?? SdkTransportSettings())
    }

    // the snapshot fields define equality; the sdk reference is the source
    static func == (lhs: TransportSettings, rhs: TransportSettings) -> Bool {
        lhs.singleTransport == rhs.singleTransport
            && lhs.autoTransports == rhs.autoTransports
            && lhs.enabledTransports == rhs.enabledTransports
    }
}

/**
 * Which device policy a transport settings surface edits: the client policy
 * (the carrier this device uses to reach providers) or the provider policy
 * (the carrier it uses when relaying for remote clients)
 */
enum TransportSettingsKind {
    case client
    case provider

    var defaultSettings: TransportSettings {
        switch self {
        case .client: return TransportSettings.defaultClient
        case .provider: return TransportSettings.defaultProvider
        }
    }
}

private class TransportSettingsListener: NSObject, SdkTransportSettingsChangeListenerProtocol {
    private let callback: (SdkTransportSettings?) -> Void
    init(callback: @escaping (SdkTransportSettings?) -> Void) {
        self.callback = callback
    }
    func transportSettingsChanged(_ transportSettings: SdkTransportSettings?) {
        callback(transportSettings)
    }
}

private class ProviderTransportSettingsListener: NSObject, SdkProviderTransportSettingsChangeListenerProtocol {
    private let callback: (SdkTransportSettings?) -> Void
    init(callback: @escaping (SdkTransportSettings?) -> Void) {
        self.callback = callback
    }
    func providerTransportSettingsChanged(_ transportSettings: SdkTransportSettings?) {
        callback(transportSettings)
    }
}

/**
 * Publishes the device transport settings (client and provider) and applies
 * edits.
 *
 * The device's change listeners deliver every change: an edit applied through
 * the rpc (fired by the extension's device), an edit queued while the tunnel
 * is down (fired locally by the device remote), and the extension's persisted
 * policy again on every rpc sync -- so the published value is the truth in
 * force. One initial read covers the time before the first event.
 *
 * Persistence: the device persists the settings in its own local state and
 * restores them when it is created, so a policy set while the tunnel runs
 * survives extension restarts. The app and the extension do not share storage
 * on Apple platforms, so the store also mirrors every edit into the app's local
 * state, and `DeviceManager.initDevice` seeds the device from that mirror on
 * launch. That way an edit made while the tunnel is down is queued on the
 * device remote and applied (then persisted extension-side) on the next
 * connect, even across an app relaunch, and the offline reads return the
 * edited policy rather than the default.
 */
@MainActor
class TransportSettingsStore: ObservableObject {

    @Published private(set) var clientSettings: TransportSettings? = nil
    @Published private(set) var providerSettings: TransportSettings? = nil

    private var device: SdkDeviceRemote?
    private var localState: SdkLocalState?
    private var clientSub: SdkSubProtocol?
    private var providerSub: SdkSubProtocol?

    func setup(_ device: SdkDeviceRemote, localState: SdkLocalState?) {
        reset()

        self.device = device
        self.localState = localState

        self.clientSub = device.add(TransportSettingsListener { [weak self] sdkSettings in
            DispatchQueue.main.async {
                self?.publish(sdkSettings, kind: .client)
            }
        })
        self.providerSub = device.add(ProviderTransportSettingsListener { [weak self] sdkSettings in
            DispatchQueue.main.async {
                self?.publish(sdkSettings, kind: .provider)
            }
        })

        refresh()
    }

    func reset() {
        clientSub?.close()
        clientSub = nil
        providerSub?.close()
        providerSub = nil
        device = nil
        localState = nil
        clientSettings = nil
        providerSettings = nil
    }

    func settings(_ kind: TransportSettingsKind) -> TransportSettings? {
        switch kind {
        case .client: return clientSettings
        case .provider: return providerSettings
        }
    }

    /**
     * Re-reads both policies from the device. Offline this returns the pending
     * or last known policy (see the class note).
     */
    func refresh() {
        guard let device = self.device else {
            return
        }
        publish(device.getTransportSettings(), kind: .client)
        publish(device.getProviderTransportSettings(), kind: .provider)
    }

    /**
     * Publishes a policy delivered by the device. nil (a device with no policy
     * at all) keeps the published value stable rather than flashing to nil
     */
    private func publish(_ sdkSettings: SdkTransportSettings?, kind: TransportSettingsKind) {
        guard let sdkSettings else {
            return
        }
        let settings = TransportSettings(sdkSettings)
        switch kind {
        case .client:
            if settings != clientSettings {
                clientSettings = settings
            }
        case .provider:
            if settings != providerSettings {
                providerSettings = settings
            }
        }
    }

    /**
     * Applies a policy to the device and mirrors it into the app local state.
     * The applied policy comes back through the change listener (from the
     * extension when connected, from the device remote's queue when not).
     */
    func apply(_ sdkSettings: SdkTransportSettings, kind: TransportSettingsKind) {
        guard let device = self.device else {
            return
        }
        switch kind {
        case .client:
            device.setTransportSettings(sdkSettings)
            do {
                try localState?.setTransportSettings(sdkSettings)
            } catch {
                print("[TransportSettingsStore] failed to persist client transport settings: \(error.localizedDescription)")
            }
        case .provider:
            device.setProviderTransportSettings(sdkSettings)
            do {
                try localState?.setProviderTransportSettings(sdkSettings)
            } catch {
                print("[TransportSettingsStore] failed to persist provider transport settings: \(error.localizedDescription)")
            }
        }
    }
}
