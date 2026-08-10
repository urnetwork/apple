import Foundation
import XCTest

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

final class networkUITests: XCTestCase {
    private enum AcceptanceError: Error {
        case missingEnvironment(String)
        case unexpectedInitialState
    }

    private var app: XCUIApplication!
    private var repetition = 0

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    @MainActor
    func testMainAcceptance() throws {
        let environment = ProcessInfo.processInfo.environment
        let user = try requiredEnvironment("UR_ACCEPT_USER", environment)
        let password = try requiredEnvironment("UR_ACCEPT_PASS", environment)
        let expectedBuildID = try requiredEnvironment("UR_ACCEPT_BUILD_ID", environment)
        let platform = try requiredEnvironment("UR_ACCEPT_PLATFORM", environment)
        let repetitions = Int(environment["UR_ACCEPT_REPEAT"] ?? "1") ?? 0
        XCTAssertGreaterThan(repetitions, 0, "UR_ACCEPT_REPEAT must be positive")
        XCTAssertTrue(platform == "ios" || platform == "macos")

        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
        let marker = element("acceptance.build.id")
        XCTAssertTrue(marker.waitForExistence(timeout: 30), "local-build marker is missing")
        XCTAssertEqual(marker.label, expectedBuildID, "a stale app is running")
        let environmentMarker = element("acceptance.environment")
        XCTAssertTrue(environmentMarker.waitForExistence(timeout: 30), "environment marker is missing")
        XCTAssertEqual(environmentMarker.label, "main", "acceptance app is not targeting main")

        try ensureLoggedOut()
        var secretKey = normalizedSecret(environment["UR_ACCEPT_SECRET"])

        for current in 1...repetitions {
            repetition = current
            print("UR_ACCEPTANCE_BEGIN repetition=\(current)/\(repetitions) platform=\(platform)")
            do {
                if let existingSecret = secretKey {
                    try loginWithSecretKey(existingSecret)
                } else {
                    secretKey = try createInstantAccount()
                }
                let guestNetworkID = try currentNetworkID()
                attachScreenshot("\(current)-instant-account")
                try logoutThroughUI()

                try loginWithSecretKey(XCTUnwrap(secretKey))
                XCTAssertEqual(
                    try currentNetworkID(),
                    guestNetworkID,
                    "secret-key login recovered a different network"
                )
                attachScreenshot("\(current)-secret-key-login")
                try logoutThroughUI()

                try loginWithPassword(user: user, password: password)
                print("UR_ACCEPTANCE_CLIENT id=\(try currentClientID())")
                if platform == "macos" {
                    try connectAndVerifyEgress()
                } else {
                    let connect = element("acceptance.connect")
                    XCTAssertTrue(connect.waitForExistence(timeout: 90))
                    XCTAssertTrue(connect.isEnabled, "iOS simulator did not reach an enabled Connect control")
                    attachScreenshot("\(current)-connect-reachable")
                }
                try logoutThroughUI()
                print("UR_ACCEPTANCE_PASS repetition=\(current)/\(repetitions) platform=\(platform)")
            } catch {
                attachScreenshot("\(current)-failure")
                try? recoverToLoggedOut()
                throw error
            }
        }
    }

    private func requiredEnvironment(
        _ name: String,
        _ environment: [String: String]
    ) throws -> String {
        guard let value = environment[name], !value.isEmpty else {
            XCTFail("missing \(name); run through apple/test-main.sh")
            throw AcceptanceError.missingEnvironment(name)
        }
        return value
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func tap(_ identifier: String, timeout: TimeInterval = 30) throws {
        let target = element(identifier)
        XCTAssertTrue(target.waitForExistence(timeout: timeout), "missing UI control \(identifier)")
        for _ in 0..<8 where !target.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(target.isHittable, "UI control is not hittable: \(identifier)")
        target.tap()
    }

    private func enter(_ value: String, in identifier: String) throws {
        let field = element(identifier)
        XCTAssertTrue(field.waitForExistence(timeout: 30), "missing input \(identifier)")
        for _ in 0..<8 where !field.isHittable {
            app.swipeUp()
        }
        field.tap()
        #if os(macOS)
        field.typeKey("a", modifierFlags: .command)
        #endif
        field.typeText(value)
    }

    private func waitForMain() throws {
        let close = app.buttons["Close"].firstMatch
        if close.waitForExistence(timeout: 10), close.isHittable {
            close.tap()
        }
        let connect = element("acceptance.connect")
        XCTAssertTrue(connect.waitForExistence(timeout: 90), "main Connect screen did not become ready")
    }

    private func currentNetworkID() throws -> String {
        let marker = element("acceptance.network.id")
        XCTAssertTrue(marker.waitForExistence(timeout: 30), "authenticated app exposed no network ID")
        guard !marker.label.isEmpty else {
            XCTFail("authenticated app exposed an empty network ID")
            throw AcceptanceError.unexpectedInitialState
        }
        return marker.label
    }

    private func currentClientID() throws -> String {
        let marker = element("acceptance.client.id")
        XCTAssertTrue(marker.waitForExistence(timeout: 30), "authenticated app exposed no client ID")
        guard !marker.label.isEmpty else {
            XCTFail("authenticated app exposed an empty client ID")
            throw AcceptanceError.unexpectedInitialState
        }
        return marker.label
    }

    private func createInstantAccount() throws -> String {
        print("UR_ACCEPTANCE_STEP create-instant-account")
        try tap("acceptance.login.instant")
        try tap("acceptance.instant.terms")
        try tap("acceptance.instant.create")
        let copy = element("acceptance.instant.copy")
        XCTAssertTrue(copy.waitForExistence(timeout: 90), "seedphrase screen did not appear")
        let seedphrase = element("acceptance.instant.seedphrase")
        XCTAssertTrue(seedphrase.waitForExistence(timeout: 30), "seedphrase value is missing")
        copy.tap()
        let secretKey = try XCTUnwrap(
            normalizedSecret(seedphrase.label),
            "seedphrase screen did not expose a valid 24-word secret key"
        )
        try tap("acceptance.instant.continue")
        try waitForMain()
        return secretKey
    }

    private func loginWithSecretKey(_ secretKey: String) throws {
        print("UR_ACCEPTANCE_STEP login-secret-key")
        try tap("acceptance.login.secret")
        try enter(secretKey, in: "acceptance.secret.input")
        try tap("acceptance.secret.submit")
        try waitForMain()
    }

    private func loginWithPassword(user: String, password: String) throws {
        print("UR_ACCEPTANCE_STEP login-password")
        try enter(user, in: "acceptance.password.user")
        try tap("acceptance.password.next")
        try enter(password, in: "acceptance.password.input")
        try tap("acceptance.password.submit")
        try waitForMain()
    }

    private func navigateToAccount() throws {
        let accountTab = app.tabBars.buttons["Account"].firstMatch
        if accountTab.exists {
            accountTab.tap()
            return
        }

        let accountText = app.staticTexts["Account"].firstMatch
        XCTAssertTrue(accountText.waitForExistence(timeout: 30), "Account navigation is missing")
        accountText.tap()
    }

    private func logoutThroughUI() throws {
        print("UR_ACCEPTANCE_STEP logout")
        try navigateToAccount()
        try tap("acceptance.account.menu")
        try tap("acceptance.account.logout")
        XCTAssertTrue(
            element("acceptance.password.user").waitForExistence(timeout: 90),
            "login screen did not return after logout"
        )
        XCTAssertFalse(element("acceptance.network.id").exists, "logout retained the SDK network session")
    }

    private func ensureLoggedOut() throws {
        if element("acceptance.password.user").waitForExistence(timeout: 5) {
            return
        }
        if element("acceptance.connect").waitForExistence(timeout: 30) {
            try logoutThroughUI()
            return
        }
        XCTFail("app did not reach either login or main UI")
        throw AcceptanceError.unexpectedInitialState
    }

    private func recoverToLoggedOut() throws {
        if element("acceptance.disconnect").exists {
            element("acceptance.disconnect").tap()
            _ = element("acceptance.connect").waitForExistence(timeout: 30)
        }
        if element("acceptance.password.user").exists { return }
        try logoutThroughUI()
    }

    private func connectAndVerifyEgress() throws {
        let before = try publicIP()
        print("UR_ACCEPTANCE_STEP egress-before=\(before)")

        addUIInterruptionMonitor(withDescription: "VPN configuration") { alert in
            for label in ["Allow", "OK", "Approve"] {
                let button = alert.buttons[label]
                if button.exists {
                    button.tap()
                    return true
                }
            }
            return false
        }

        try tap("acceptance.connect")
        app.tap()
        let connected = NSPredicate { object, _ in
            guard let element = object as? XCUIElement else { return false }
            return element.exists && element.label.hasPrefix("Connected to ")
        }
        expectation(for: connected, evaluatedWith: element("acceptance.connect.status"))
        waitForExpectations(timeout: 120)
        XCTAssertTrue(element("acceptance.disconnect").waitForExistence(timeout: 30))
        attachScreenshot("\(repetition)-connected")

        let after = try publicIP()
        print("UR_ACCEPTANCE_STEP egress-after=\(after)")
        XCTAssertNotEqual(before, after, "public IP did not change after Connect")

        try tap("acceptance.disconnect")
        XCTAssertTrue(element("acceptance.connect").waitForExistence(timeout: 90))
        attachScreenshot("\(repetition)-disconnected")
    }

    private func publicIP() throws -> String {
        let result = expectation(description: "public IP request")
        var received: Result<String, Error>?
        var request = URLRequest(url: URL(string: "https://checkip.amazonaws.com")!)
        request.timeoutInterval = 20
        URLSession(configuration: .ephemeral).dataTask(with: request) { data, response, error in
            defer { result.fulfill() }
            if let error {
                received = .failure(error)
                return
            }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let data, let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else {
                received = .failure(NSError(domain: "URAcceptance", code: 1))
                return
            }
            received = .success(value)
        }.resume()
        wait(for: [result], timeout: 30)
        return try XCTUnwrap(received).get()
    }

    private func normalizedSecret(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return normalized.split(separator: " ").count == 24 ? normalized : nil
    }

    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
