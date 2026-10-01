//
//  NetworkConfig.swift
//  URnetwork
//
//  Default network space values for the official URnetwork server. These are
//  the same values `DeviceManager.initializeNetworkSpace()` used to hardcode
//  inline; naming them here lets the network-server selector (see
//  `NetworkServerSheet`) reset back to these defaults, mirroring how the
//  Android app's per-flavor `BuildConfig.BRINGYOUR_BUNDLE_*` constants work.
//
//  Note: `wallet` is `"circle"` here, not `"solana"` - this is intentionally
//  different from Android's flavors and governs the app's own concept of a
//  wallet, separate from the "Sign in with Solana" wallet-login feature.
//  Do not change this to match Android without confirming what it controls.
//

import Foundation

struct NetworkConfig {
    // The operator stays bringyour.com: the planned move to *.ur.network was
    // cancelled, so the bundled space is keyed by the host its services really
    // resolve under and carries no migration host. The link host (ur.io) is
    // the web site and is unrelated to the operator host.
    static let officialHostName = "bringyour.com"
    static let officialEnvName = "main"
    static let officialLinkHostName = "ur.io"

    // The bundled key before the operator decision. Installs created by those
    // builds keep their state under `network_spaces/ur.network/main`;
    // `NetworkSpaceStartup` moves it to the official key once, on launch, so
    // they stay signed in.
    static let legacyOfficialHostName = "ur.network"

    static let envSecret = ""
    static let store = ""
    static let wallet = "circle"
    static let ssoGoogle = false
    static let netExposeServerIps = true
    static let netExposeServerHostNames = true
}
