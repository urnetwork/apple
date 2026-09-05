// SPDX-License-Identifier: MPL-2.0

import XCTest

final class HardwareStartupNoVPNUITests: XCTestCase {
    private let launchArgument = "--urnetwork-hardware-startup-no-vpn"
    private let enabledEnvironmentKey = "UR_HARDWARE_UI_NO_VPN"
    private let nonceEnvironmentKey = "UR_HARDWARE_UI_TEST_NONCE"
    private let deviceEnvironmentKey = "UR_HARDWARE_UI_DEVICE_ID"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testDeviceStartsWithoutVPNProfileAccess() throws {
        let environment = ProcessInfo.processInfo.environment
        let nonce = try XCTUnwrap(environment[nonceEnvironmentKey])
        let plannedDeviceID = try XCTUnwrap(environment[deviceEnvironmentKey])
        XCTAssertTrue(
            nonce.range(
                of: #"\A[0-9a-f]{32}\z"#,
                options: .regularExpression
            ) != nil,
            "the runner must supply its build-paired nonce"
        )
        XCTAssertTrue(
            plannedDeviceID.range(
                of: #"\A[A-Za-z0-9-]+\z"#,
                options: .regularExpression
            ) != nil,
            "the runner must identify the immutable planned device"
        )

        let app = XCUIApplication()
        app.launchArguments = [launchArgument]
        app.launchEnvironment = [
            enabledEnvironmentKey: "1",
            nonceEnvironmentKey: nonce,
        ]
        app.launch()

        let ready = element("hardware.startup.no-vpn.active", in: app)
        XCTAssertTrue(
            ready.waitForExistence(timeout: 20),
            "the app did not enter the compile-time-gated no-VPN startup mode"
        )
        XCTAssertFalse(
            element("hardware.startup.request-rejected", in: app).exists,
            "the app rejected the paired hardware startup request"
        )

        let startupInitializerCount = element(
            "hardware.startup.device-initializer-invocation-count",
            in: app
        )
        XCTAssertTrue(startupInitializerCount.exists)
        XCTAssertEqual(startupInitializerCount.label, "1")
        let vpnManagerCount = element(
            "hardware.startup.vpn-manager-invocation-count",
            in: app
        )
        XCTAssertTrue(vpnManagerCount.exists)
        XCTAssertEqual(vpnManagerCount.label, "0")

        XCTAssertTrue(
            app.textFields["acceptance.password.user"].waitForExistence(timeout: 30),
            "normal API/login UI did not finish starting in no-VPN mode"
        )

        // Any SpringBoard alert is a fail-closed prerequisite violation for
        // this unattended lane. In particular, normal startup used to reach
        // NETunnelProviderManager and present the Install VPN Profile alert.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCTAssertFalse(
            springboard.alerts.firstMatch.waitForExistence(timeout: 3),
            "a system alert interrupted the no-VPN hardware startup lane"
        )

        app.terminate()
        print("UR_HARDWARE_STARTUP_PASS device=\(plannedDeviceID)")
    }

    private func element(
        _ identifier: String,
        in application: XCUIApplication
    ) -> XCUIElement {
        // AcceptanceMarker deliberately collapses its SwiftUI Text into one
        // accessibility element. XCTest exposes that element as `Other` on
        // current iOS releases, so its stable identifier—not an inferred
        // element type—is the contract.
        application.descendants(matching: .any)
            .matching(identifier: identifier)
            .firstMatch
    }
}
