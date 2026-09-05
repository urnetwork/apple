// SPDX-License-Identifier: MPL-2.0

import Foundation

enum AppStartupMode: Equatable {
    case production
    case hardwareNoVPN
    case rejectedHardwareTestRequest

    var allowsStartupInitialization: Bool {
        self != .rejectedHardwareTestRequest
    }

    var allowsVPNProfileSystemAccess: Bool {
        self == .production
    }
}

/// The iOS-device startup lane is intentionally a different app mode,
/// not a UI-test race against normal initialization.  A production binary
/// cannot resolve this mode: the only call site that enables `testSupportCompiled`
/// is compiled under both DEBUG and the lane-specific build condition.
struct HardwareNoVPNLaunchContract {
    static let launchArgument = "--urnetwork-hardware-startup-no-vpn"
    static let enabledEnvironmentKey = "UR_HARDWARE_UI_NO_VPN"
    static let nonceEnvironmentKey = "UR_HARDWARE_UI_TEST_NONCE"
    static let nonceInfoKey = "URHardwareUITestNonce"

    private static let tunnelEnvironmentKeys = [
        "UR_ACCEPT_USER",
        "UR_ACCEPT_PASS",
        "UR_ACCEPT_SECRET",
        "UR_ACCEPT_PEER_ID",
        "UR_PHYSICAL_PEER_TEST_ROLE",
        "UR_COLD_RELAUNCH_MODE",
    ]

    static func resolve(
        arguments: [String],
        environment: [String: String],
        bundledNonce: String?,
        testSupportCompiled: Bool
    ) -> AppStartupMode {
        // This first guard is the production invariant. Even a complete,
        // correctly paired launch request cannot opt a normal binary out of
        // VPN initialization.
        guard testSupportCompiled else {
            return .production
        }

        let argumentCount = arguments.filter { $0 == launchArgument }.count
        let enabledValue = environment[enabledEnvironmentKey]
        let suppliedNonce = environment[nonceEnvironmentKey]
        let hasAnyHardwareRequest = argumentCount != 0
            || enabledValue != nil
            || suppliedNonce != nil

        guard hasAnyHardwareRequest else {
            return .production
        }

        let tunnelRequested = tunnelEnvironmentKeys.contains { key in
            guard let value = environment[key] else { return false }
            return !value.isEmpty
        }
        guard !tunnelRequested,
              argumentCount == 1,
              enabledValue == "1",
              let bundledNonce,
              isValidNonce(bundledNonce),
              suppliedNonce == bundledNonce else {
            // A malformed or mixed-mode request in a UI-test-capable build
            // fails closed without entering either normal startup or the
            // privileged no-VPN readiness view.
            return .rejectedHardwareTestRequest
        }

        return .hardwareNoVPN
    }

    static var current: AppStartupMode {
        #if DEBUG && URNETWORK_HARDWARE_UI_TESTING && os(iOS)
        return resolve(
            arguments: ProcessInfo.processInfo.arguments,
            environment: ProcessInfo.processInfo.environment,
            bundledNonce: Bundle.main.object(
                forInfoDictionaryKey: nonceInfoKey
            ) as? String,
            testSupportCompiled: true
        )
        #else
        return .production
        #endif
    }

    private static func isValidNonce(_ value: String) -> Bool {
        value.count == 32 && value.allSatisfy { character in
            ("0"..."9").contains(character)
                || ("a"..."f").contains(character)
        }
    }
}

struct AppStartupInitializationGate {
    @discardableResult
    static func performIfAllowed(
        mode: AppStartupMode,
        operation: () -> Void
    ) -> Bool {
        guard mode.allowsStartupInitialization else {
            return false
        }
        operation()
        return true
    }
}
