// SPDX-License-Identifier: MPL-2.0

import Testing
@testable import URnetwork

struct AppStartupModeTests {
    private let nonce = "0123456789abcdef0123456789abcdef"

    @Test func productionBinaryCannotEnableNoVPNMode() {
        let mode = HardwareNoVPNLaunchContract.resolve(
            arguments: [HardwareNoVPNLaunchContract.launchArgument],
            environment: [
                HardwareNoVPNLaunchContract.enabledEnvironmentKey: "1",
                HardwareNoVPNLaunchContract.nonceEnvironmentKey: nonce,
            ],
            bundledNonce: nonce,
            testSupportCompiled: false
        )

        #expect(mode == .production)
        #expect(mode.allowsStartupInitialization)
        #expect(mode.allowsVPNProfileSystemAccess)
    }

    @Test func completePairedTestRequestEnablesNoVPNMode() {
        let mode = resolveTestRequest()

        #expect(mode == .hardwareNoVPN)
        #expect(mode.allowsStartupInitialization)
        #expect(!mode.allowsVPNProfileSystemAccess)
    }

    @Test func partialAndForgedRequestsFailClosed() {
        let argumentOnly = HardwareNoVPNLaunchContract.resolve(
            arguments: [HardwareNoVPNLaunchContract.launchArgument],
            environment: [:],
            bundledNonce: nonce,
            testSupportCompiled: true
        )
        let wrongNonce = HardwareNoVPNLaunchContract.resolve(
            arguments: [HardwareNoVPNLaunchContract.launchArgument],
            environment: [
                HardwareNoVPNLaunchContract.enabledEnvironmentKey: "1",
                HardwareNoVPNLaunchContract.nonceEnvironmentKey:
                    "ffffffffffffffffffffffffffffffff",
            ],
            bundledNonce: nonce,
            testSupportCompiled: true
        )
        let duplicatedArgument = HardwareNoVPNLaunchContract.resolve(
            arguments: [
                HardwareNoVPNLaunchContract.launchArgument,
                HardwareNoVPNLaunchContract.launchArgument,
            ],
            environment: [
                HardwareNoVPNLaunchContract.enabledEnvironmentKey: "1",
                HardwareNoVPNLaunchContract.nonceEnvironmentKey: nonce,
            ],
            bundledNonce: nonce,
            testSupportCompiled: true
        )
        let nonASCIIDigits = String(repeating: "١", count: 32)
        let nonHexNonce = HardwareNoVPNLaunchContract.resolve(
            arguments: [HardwareNoVPNLaunchContract.launchArgument],
            environment: [
                HardwareNoVPNLaunchContract.enabledEnvironmentKey: "1",
                HardwareNoVPNLaunchContract.nonceEnvironmentKey:
                    nonASCIIDigits,
            ],
            bundledNonce: nonASCIIDigits,
            testSupportCompiled: true
        )

        #expect(argumentOnly == .rejectedHardwareTestRequest)
        #expect(wrongNonce == .rejectedHardwareTestRequest)
        #expect(duplicatedArgument == .rejectedHardwareTestRequest)
        #expect(nonHexNonce == .rejectedHardwareTestRequest)
        #expect(!argumentOnly.allowsStartupInitialization)
        #expect(!wrongNonce.allowsVPNProfileSystemAccess)
    }

    @Test func tunnelRequestCannotEnterHardwareStartupLane() {
        let mode = HardwareNoVPNLaunchContract.resolve(
            arguments: [HardwareNoVPNLaunchContract.launchArgument],
            environment: [
                HardwareNoVPNLaunchContract.enabledEnvironmentKey: "1",
                HardwareNoVPNLaunchContract.nonceEnvironmentKey: nonce,
                "UR_ACCEPT_USER": "tunnel-test-requested",
            ],
            bundledNonce: nonce,
            testSupportCompiled: true
        )

        #expect(mode == .rejectedHardwareTestRequest)
        #expect(!mode.allowsStartupInitialization)
        #expect(!mode.allowsVPNProfileSystemAccess)
    }

    @Test func noVPNModePreservesStartupButInvokesNoProfileOperation() {
        var startupInvocations = 0
        var profileInvocations = 0
        let mode = resolveTestRequest()

        let initialized = AppStartupInitializationGate.performIfAllowed(
            mode: mode
        ) {
            startupInvocations += 1
        }
        let accessedProfile = VPNProfileSystem.performIfAllowed(mode: mode) {
            profileInvocations += 1
        }

        #expect(initialized)
        #expect(!accessedProfile)
        #expect(startupInvocations == 1)
        #expect(profileInvocations == 0)
    }

    @Test func productionModePreservesNormalInitialization() {
        var startupInvocations = 0
        var profileInvocations = 0

        let initialized = AppStartupInitializationGate.performIfAllowed(
            mode: .production
        ) {
            startupInvocations += 1
        }
        let accessedProfile = VPNProfileSystem.performIfAllowed(
            mode: .production
        ) {
            profileInvocations += 1
        }

        #expect(initialized)
        #expect(accessedProfile)
        #expect(startupInvocations == 1)
        #expect(profileInvocations == 1)
    }

    #if DEBUG && URNETWORK_HARDWARE_UI_TESTING && os(iOS)
    @Test func hardwareCorpusHostRequiresPairedNoVPNLaunchContract() {
        // The shell runner validates the xctestrun before launch. This
        // app-hosted assertion independently makes the full networkTests
        // corpus fail if its argument/environment/build nonce pairing is
        // absent or malformed.
        #expect(HardwareNoVPNLaunchContract.current == .hardwareNoVPN)
    }
    #endif

    private func resolveTestRequest() -> AppStartupMode {
        HardwareNoVPNLaunchContract.resolve(
            arguments: [HardwareNoVPNLaunchContract.launchArgument],
            environment: [
                HardwareNoVPNLaunchContract.enabledEnvironmentKey: "1",
                HardwareNoVPNLaunchContract.nonceEnvironmentKey: nonce,
            ],
            bundledNonce: nonce,
            testSupportCompiled: true
        )
    }
}
