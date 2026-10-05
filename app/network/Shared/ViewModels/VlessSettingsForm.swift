//
//  VlessSettingsForm.swift
//  URnetwork
//

import Foundation

/**
 * The VLESS settings form (connect issue 91): one VLESS server of a network
 * space, which the client strategy also dials through while it is enabled.
 * Account > Settings > VLESS and the VLESS row of the login screen's network
 * sheet edit it.
 *
 * Only plain values live here, so the form's rules are tested without a device
 * or the sdk: which fields the form shows, the form <-> settings mapping, and
 * the message of an sdk error id. Validating, reading a link and storing are
 * the sdk's (`ValidateVlessSettings`, `ParseVlessLink`,
 * `NetworkSpace.SetVlessSettings`), one implementation for every app;
 * `VlessSettingsStore` adapts between the two.
 */

// MARK: - values

/// The sdk's `VlessSettings`, field for field, as Swift values.
struct VlessSettingsValues: Equatable, Sendable {
    var enabled: Bool = false
    var name: String = ""
    var address: String = ""
    var port: Int = 0
    var id: String = ""
    var flow: String = ""
    var network: String = ""
    var security: String = ""
    var serverName: String = ""
    var fingerprint: String = ""
    var alpn: String = ""
    var allowInsecure: Bool = false
    var publicKey: String = ""
    var shortId: String = ""
    var spiderX: String = ""
    var path: String = ""
    var host: String = ""
}

// MARK: - options

/// One choice of a picker: the sdk value and what the picker shows for it.
struct VlessSettingsOption: Identifiable {
    let value: String
    let label: LocalizedStringResource

    var id: String { value }
}

/// The choices the form offers, in the sdk's order (`VlessNetworks`,
/// `VlessSecurities`, `VlessFlows`, `VlessFingerprints`).
enum VlessSettingsOptions {

    static let networkTcp = "tcp"
    static let networkWs = "ws"
    static let networkHttpUpgrade = "httpupgrade"

    static let securityNone = "none"
    static let securityTls = "tls"
    static let securityReality = "reality"

    static let flowNone = ""
    static let flowVision = "xtls-rprx-vision"

    static let networks: [VlessSettingsOption] = [
        VlessSettingsOption(value: networkTcp, label: "TCP"),
        VlessSettingsOption(value: networkWs, label: "WebSocket"),
        VlessSettingsOption(value: networkHttpUpgrade, label: "HTTPUpgrade"),
    ]

    static let securities: [VlessSettingsOption] = [
        VlessSettingsOption(value: securityNone, label: "None"),
        VlessSettingsOption(value: securityTls, label: "TLS"),
        VlessSettingsOption(value: securityReality, label: "REALITY"),
    ]

    static let flows: [VlessSettingsOption] = [
        VlessSettingsOption(value: flowNone, label: "None"),
        VlessSettingsOption(value: flowVision, label: "Vision"),
    ]

    /// The tls client hellos. The empty one is the Go tls client for tls and
    /// chrome for REALITY; the named ones are technical values, shown as they
    /// are spelled.
    static let fingerprints: [String] = [
        "", "chrome", "firefox", "safari", "ios", "android", "edge", "360", "qq", "random", "randomized",
    ]

    /// What the fingerprint picker shows for the empty fingerprint. nil for a
    /// named one, which is shown verbatim.
    static func fingerprintLabel(_ fingerprint: String) -> LocalizedStringResource? {
        fingerprint.isEmpty ? "None" : nil
    }

    /// The placeholders of two empty fields: the link's scheme, and the path
    /// the http transports request when the path is empty. Technical text,
    /// spelled the same in every language.
    static let linkPlaceholder = "vless://"
    static let pathPlaceholder = "/"
}

// MARK: - form

/**
 * What the editor binds to. Every value stays in the form while the field that
 * shows it is hidden, so switching the transport or the security back brings
 * it back.
 */
struct VlessSettingsForm: Equatable {
    var enabled: Bool = false
    var name: String = ""
    var address: String = ""
    /// the port as typed; text that is not a port saves as 0, which the sdk
    /// reports as an invalid port
    var port: String = ""
    var id: String = ""
    var network: String = VlessSettingsOptions.networkTcp
    var security: String = VlessSettingsOptions.securityNone
    var flow: String = VlessSettingsOptions.flowNone
    var serverName: String = ""
    var fingerprint: String = ""
    var alpn: String = ""
    var allowInsecure: Bool = false
    var publicKey: String = ""
    var shortId: String = ""
    var path: String = ""
    var host: String = ""
    /// The REALITY spider path a pasted link carried. The form does not edit
    /// it; it is kept so a link copied from the saved settings reads the same.
    var spiderX: String = ""

    init() {}

    init(_ settings: VlessSettingsValues) {
        enabled = settings.enabled
        name = settings.name
        address = settings.address
        port = 0 < settings.port ? String(settings.port) : ""
        id = settings.id
        // the empty transport and security are the sdk's defaults, tcp and none
        network = settings.network.isEmpty ? VlessSettingsOptions.networkTcp : settings.network
        security = settings.security.isEmpty ? VlessSettingsOptions.securityNone : settings.security
        flow = settings.flow
        serverName = settings.serverName
        fingerprint = settings.fingerprint
        alpn = settings.alpn
        allowInsecure = settings.allowInsecure
        publicKey = settings.publicKey
        shortId = settings.shortId
        path = settings.path
        host = settings.host
        spiderX = settings.spiderX
    }

    // MARK: what the form shows

    /// The flow applies only to raw tcp under tls or REALITY: Vision pads the
    /// inner tls handshake straight on the stream.
    var showsFlow: Bool {
        network == VlessSettingsOptions.networkTcp && security != VlessSettingsOptions.securityNone
    }

    /// The server name and the tls fingerprint, for every security that runs a
    /// tls handshake.
    var showsTlsHandshake: Bool {
        security != VlessSettingsOptions.securityNone
    }

    /// The ALPN list and the insecure certificate switch, for tls only.
    var showsTlsOptions: Bool {
        security == VlessSettingsOptions.securityTls
    }

    /// The public key and the short id.
    var showsReality: Bool {
        security == VlessSettingsOptions.securityReality
    }

    /// The http path and host header of the WebSocket and HTTPUpgrade
    /// transports.
    var showsHttp: Bool {
        network == VlessSettingsOptions.networkWs || network == VlessSettingsOptions.networkHttpUpgrade
    }

    // MARK: the settings it saves

    /**
     * The settings the form saves. The values of hidden fields are kept: the
     * sdk ignores the ones that do not apply, and the spider path rides along
     * for the share link. The flow is the exception. Vision is valid only
     * where the flow picker shows, so a hidden flow saves as none instead of
     * failing validation with an error about a field the user cannot see.
     */
    var settings: VlessSettingsValues {
        VlessSettingsValues(
            enabled: enabled,
            name: name,
            address: address,
            port: vlessSettingsPort(port),
            id: id,
            flow: showsFlow ? flow : VlessSettingsOptions.flowNone,
            network: network,
            security: security,
            serverName: serverName,
            fingerprint: fingerprint,
            alpn: alpn,
            allowInsecure: allowInsecure,
            publicKey: publicKey,
            shortId: shortId,
            spiderX: spiderX,
            path: path,
            host: host
        )
    }
}

/// The port of the port field: the number typed, or 0 for anything else.
func vlessSettingsPort(_ text: String) -> Int {
    Int(text.trimmingCharacters(in: .whitespaces)) ?? 0
}

/// The port field keeps digits only. The iOS number pad types nothing else,
/// but a paste or a Mac keyboard can.
func vlessSettingsPortText(_ text: String) -> String {
    text.filter { "0123456789".contains($0) }
}

// MARK: - errors

/// The sdk's error ids (`SdkVlessError*`). Each id is also the localization
/// key id of its message in the localizations store.
enum VlessSettingsErrorId {
    static let linkInvalid = "vless_error_link_invalid"
    static let linkUnsupported = "vless_error_link_unsupported"
    static let addressInvalid = "vless_error_address_invalid"
    static let portInvalid = "vless_error_port_invalid"
    static let idInvalid = "vless_error_id_invalid"
    static let networkUnsupported = "vless_error_network_unsupported"
    static let securityUnsupported = "vless_error_security_unsupported"
    static let flowInvalid = "vless_error_flow_invalid"
    static let serverNameRequired = "vless_error_server_name_required"
    static let fingerprintUnsupported = "vless_error_fingerprint_unsupported"
    static let publicKeyInvalid = "vless_error_public_key_invalid"
    static let shortIdInvalid = "vless_error_short_id_invalid"

    static let all: [String] = [
        linkInvalid,
        linkUnsupported,
        addressInvalid,
        portInvalid,
        idInvalid,
        networkUnsupported,
        securityUnsupported,
        flowInvalid,
        serverNameRequired,
        fingerprintUnsupported,
        publicKeyInvalid,
        shortIdInvalid,
    ]
}

/// The message of an sdk error id. An id this build does not know reads as an
/// invalid link, the store's catch-all.
func vlessSettingsErrorMessage(_ errorId: String) -> LocalizedStringResource {
    switch errorId {
    case VlessSettingsErrorId.linkUnsupported:
        return "This link uses a VLESS feature this app does not support."
    case VlessSettingsErrorId.addressInvalid:
        return "Enter the server address."
    case VlessSettingsErrorId.portInvalid:
        return "Enter a port from 1 to 65535."
    case VlessSettingsErrorId.idInvalid:
        return "Enter the user ID (a UUID)."
    case VlessSettingsErrorId.networkUnsupported:
        return "This transport is not supported. Use TCP, WebSocket or HTTPUpgrade."
    case VlessSettingsErrorId.securityUnsupported:
        return "This security type is not supported. Use TLS, REALITY or none."
    case VlessSettingsErrorId.flowInvalid:
        return "The Vision flow works only with the TCP transport and TLS or REALITY security."
    case VlessSettingsErrorId.serverNameRequired:
        return "Enter the server name (SNI) for REALITY."
    case VlessSettingsErrorId.fingerprintUnsupported:
        return "This TLS fingerprint is not supported."
    case VlessSettingsErrorId.publicKeyInvalid:
        return "Enter the REALITY public key."
    case VlessSettingsErrorId.shortIdInvalid:
        return "The REALITY short ID must be up to 16 hexadecimal characters."
    default:
        // vless_error_link_invalid, and any id this build does not know
        return "This is not a valid VLESS link."
    }
}
