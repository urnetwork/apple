//
//  TunnelProviderIdentity.swift
//  URnetwork
//
//  The one place the app names its own product family. The App Store build
//  is `network.ur` with the tunnel app extension `network.ur.extension`; the
//  direct-download build (`DIRECT_DOWNLOAD`, Developer ID + system
//  extension) is `com.bringyour.urnetwork` with `com.bringyour.urnetwork.extension`,
//  so the two can be installed side by side and provisioned as separate App
//  IDs. Both sets are spelled out so a test can pin them whichever flavor it
//  runs as; `Flavor` below is the set this binary was built with.
//
//  The same choice is mirrored, by hand, in the places that cannot import
//  this file: project.pbxproj (PRODUCT_BUNDLE_IDENTIFIER and the UR_*
//  Info.plist settings), the two *-direct / *-sysext entitlements files,
//  extension/Info-macOS-sysext.plist and DiagnosticsLogContract
//  .appGroupIdentifierBase (compiled into the extension targets, which do
//  not compile this file). test-direct-bundle-ids_test.go in the repo root
//  checks those files agree with this one.
//

import Foundation

enum TunnelProviderIdentity {

    struct Set: Equatable {
        /// PRODUCT_BUNDLE_IDENTIFIER of the app target.
        let appBundleIdentifier: String
        /// PRODUCT_BUNDLE_IDENTIFIER of the tunnel provider, and
        /// `NETunnelProviderProtocol.providerBundleIdentifier`.
        let tunnelBundleIdentifier: String
        /// The app group, without the team prefix macOS adds.
        let appGroupBase: String
        /// keychain-access-groups entry, without $(AppIdentifierPrefix).
        let keychainAccessGroupSuffix: String
    }

    static let appStore = Set(
        appBundleIdentifier: "network.ur",
        tunnelBundleIdentifier: "network.ur.extension",
        appGroupBase: "group.network.ur",
        keychainAccessGroupSuffix: "network.ur.tunnel-credentials"
    )

    static let direct = Set(
        appBundleIdentifier: "com.bringyour.urnetwork",
        tunnelBundleIdentifier: "com.bringyour.urnetwork.extension",
        appGroupBase: "group.com.bringyour.urnetwork",
        keychainAccessGroupSuffix: "com.bringyour.urnetwork.tunnel-credentials"
    )

    #if DIRECT_DOWNLOAD
    static let flavor = direct
    #else
    static let flavor = appStore
    #endif

    /// The provider id the tunnel manager installs and matches profiles by.
    static var bundleIdentifier: String { flavor.tunnelBundleIdentifier }
}

/// Google sign-in is configured per OAuth client, and an OAuth client is
/// tied to one bundle id: the App Store client (GIDClientID in
/// URnetwork-Info.plist, via UR_GOOGLE_CLIENT_ID) does not serve
/// `com.bringyour.urnetwork`. The direct build reads DIRECT_GOOGLE_CLIENT_ID
/// into the same key, empty until a client exists, and every Google button
/// is hidden while it is.
enum GoogleSignInConfiguration {
    static func isConfigured(clientId: String?) -> Bool {
        guard let clientId else { return false }
        return !clientId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
