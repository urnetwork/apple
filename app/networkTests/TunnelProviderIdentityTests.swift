//
//  TunnelProviderIdentityTests.swift
//  networkTests
//
//  The App Store build and the direct-download build are separate product
//  families (network.ur vs com.bringyour.urnetwork). These pin both sets,
//  the flavor this test binary was built as, and the agreement between
//  TunnelProviderIdentity and DiagnosticsLogContract (which the extension
//  targets compile separately). test-direct-bundle-ids_test.go in the repo
//  root checks the pbxproj, entitlements and plists against the same values.
//

import Testing
@testable import URnetwork

struct TunnelProviderIdentityTests {

    @Test func theTwoFamiliesAreDistinctAndComplete() {
        let store = TunnelProviderIdentity.appStore
        let direct = TunnelProviderIdentity.direct
        #expect(store.appBundleIdentifier == "network.ur")
        #expect(store.tunnelBundleIdentifier == "network.ur.extension")
        #expect(store.appGroupBase == "group.network.ur")
        #expect(store.keychainAccessGroupSuffix == "network.ur.tunnel-credentials")

        #expect(direct.appBundleIdentifier == "com.bringyour.urnetwork")
        #expect(direct.tunnelBundleIdentifier == "com.bringyour.urnetwork.extension")
        #expect(direct.appGroupBase == "group.com.bringyour.urnetwork")
        #expect(direct.keychainAccessGroupSuffix == "com.bringyour.urnetwork.tunnel-credentials")

        // the tunnel id is the app id plus ".extension", the group is
        // "group." plus the app id, in both families
        for family in [store, direct] {
            #expect(family.tunnelBundleIdentifier == family.appBundleIdentifier + ".extension")
            #expect(family.appGroupBase == "group." + family.appBundleIdentifier)
            #expect(family.keychainAccessGroupSuffix == family.appBundleIdentifier + ".tunnel-credentials")
        }
        #expect(store != direct)
    }

    @Test func theFlavorMatchesTheCompilationCondition() {
        #if DIRECT_DOWNLOAD
        #expect(TunnelProviderIdentity.flavor == TunnelProviderIdentity.direct)
        #else
        #expect(TunnelProviderIdentity.flavor == TunnelProviderIdentity.appStore)
        #endif
        #expect(TunnelProviderIdentity.bundleIdentifier == TunnelProviderIdentity.flavor.tunnelBundleIdentifier)
    }

    @Test func theLogContractUsesTheSameAppGroup() {
        // DiagnosticsLogContract cannot import this constant (it is compiled
        // into the extension targets too), so it repeats the choice
        #expect(DiagnosticsLogContract.appGroupIdentifierBase == TunnelProviderIdentity.flavor.appGroupBase)
    }

    @Test func googleSignInIsOfferedOnlyWithAClientId() {
        #expect(!GoogleSignInConfiguration.isConfigured(clientId: nil))
        #expect(!GoogleSignInConfiguration.isConfigured(clientId: ""))
        #expect(!GoogleSignInConfiguration.isConfigured(clientId: "  \n"))
        #expect(GoogleSignInConfiguration.isConfigured(clientId: "1234-abc.apps.googleusercontent.com"))
    }

    // The Developer ID profile of the direct build does not grant the
    // applesignin entitlement, so the native Apple button is App Store only.
    @Test func appleSignInIsOfferedOnlyToTheAppStoreFamily() {
        #expect(AppleSignInConfiguration.isConfigured(for: TunnelProviderIdentity.appStore))
        #expect(!AppleSignInConfiguration.isConfigured(for: TunnelProviderIdentity.direct))
        #expect(Config.isAppleSignInConfigured == AppleSignInConfiguration.isConfigured(for: TunnelProviderIdentity.flavor))
        #if DIRECT_DOWNLOAD
        #expect(!Config.isAppleSignInConfigured)
        #else
        #expect(Config.isAppleSignInConfigured)
        #endif
    }
}
