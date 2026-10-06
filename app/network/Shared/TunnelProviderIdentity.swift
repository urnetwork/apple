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
//  not compile this file), and for the macOS split tunnel system extension
//  (`<app>.splittunnel`) the splittunnel/ plists and entitlements.
//  test-direct-bundle-ids_test.go in the repo root checks those files agree
//  with this one.
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
        /// PRODUCT_BUNDLE_IDENTIFIER of the macOS split tunnel system
        /// extension (the transparent proxy that takes excluded apps out of
        /// the tunnel), and its NETransparentProxyManager's
        /// `providerBundleIdentifier`.
        let splitTunnelBundleIdentifier: String
    }

    static let appStore = Set(
        appBundleIdentifier: "network.ur",
        tunnelBundleIdentifier: "network.ur.extension",
        appGroupBase: "group.network.ur",
        keychainAccessGroupSuffix: "network.ur.tunnel-credentials",
        splitTunnelBundleIdentifier: "network.ur.splittunnel"
    )

    static let direct = Set(
        appBundleIdentifier: "com.bringyour.urnetwork",
        tunnelBundleIdentifier: "com.bringyour.urnetwork.extension",
        appGroupBase: "group.com.bringyour.urnetwork",
        keychainAccessGroupSuffix: "com.bringyour.urnetwork.tunnel-credentials",
        splitTunnelBundleIdentifier: "com.bringyour.urnetwork.splittunnel"
    )

    #if DIRECT_DOWNLOAD
    static let flavor = direct
    #else
    static let flavor = appStore
    #endif

    /// The provider id the tunnel manager installs and matches profiles by.
    static var bundleIdentifier: String { flavor.tunnelBundleIdentifier }

    /// The split tunnel system extension this binary activates and
    /// configures (macOS only; the iOS build never uses it).
    static var splitTunnelBundleIdentifier: String { flavor.splitTunnelBundleIdentifier }
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

/// Sign in with Apple needs the com.apple.developer.applesignin entitlement,
/// which a provisioning profile has to grant. The App Store profiles do; the
/// Developer ID profile the direct build is signed with ("URnetwork
/// Download") does not carry it today, so network-macOS-direct.entitlements
/// omits it and the native Apple button (login) and picker entry (Account >
/// Add sign-in method) are hidden in that family, the way the Google ones
/// are without an OAuth client. Once the capability is on the
/// com.bringyour.urnetwork App ID and the profile is regenerated, add the
/// entitlement back and make `direct` configured here.
enum AppleSignInConfiguration {
    static func isConfigured(for family: TunnelProviderIdentity.Set) -> Bool {
        family == TunnelProviderIdentity.appStore
    }

    static var isConfigured: Bool { isConfigured(for: TunnelProviderIdentity.flavor) }
}

/// The browser sign-in (BrowserSso: Google and Apple through their own web
/// flow, the api's callback returning on urnetwork://oauth/<provider>) stands
/// in for the native flows in the direct-download family, which has neither
/// the applesignin entitlement nor a Google OAuth client. The App Store
/// family keeps the native SDKs and never offers it; macOS only, the direct
/// build's one platform (an iOS build is always the App Store family).
enum BrowserSsoConfiguration {
    static func isAvailable(for family: TunnelProviderIdentity.Set) -> Bool {
        #if os(macOS)
        return family == TunnelProviderIdentity.direct
        #else
        return false
        #endif
    }

    static var isAvailable: Bool { isAvailable(for: TunnelProviderIdentity.flavor) }
}
