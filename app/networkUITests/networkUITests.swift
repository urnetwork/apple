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

    private enum PostAuthDestination: Equatable {
        case connect
        case verification
        case welcome
        case introduction
        case overlay
        case pending
    }

    private enum InputElementKind: Equatable {
        case textField
        case secureTextField
        case textView
        case nonEditable
    }

    private enum AccountNavigationTarget: Equatable {
        case macOSOutlineRow
        case tabBarButton
        case fallbackText
    }

    private struct TransitionControlState {
        let exists: Bool
        let actionable: Bool
    }

    private struct ScrollCandidateState {
        let requested: Bool
        let hittable: Bool
        let area: Double
    }

    private struct InterruptionCandidateState {
        let applicationRoot: Bool
        let exists: Bool
    }

    private struct VPNAuthorizationDialogState {
        let exists: Bool
        let allowActionExists: Bool
        let denyActionExists: Bool
    }

    private enum VPNAuthorizationAction: Equatable {
        case tapSystemAllow
        case triggerInterruptionMonitor
        case failUnrecognizedSystemPrompt
        case failMissingTrigger
    }

    private enum ScrollDirection {
        case up
        case down
    }

    // SwiftUI removes a transition button before the destination is exposed to
    // XCTest. Do not query that departing accessibility node during this grace
    // period: a second property lookup can raise an XCTest snapshot failure.
    private static let transitionRetryDelay: TimeInterval = 10
    private static let connectedStatusPrefix = "Connected to "

    private static func preferredInputElementKind(
        _ matches: [InputElementKind]
    ) -> InputElementKind? {
        // SwiftUI can propagate an input's identifier to overlay labels. Only
        // return element types that XCTest can actually focus and type into.
        for candidate in [InputElementKind.textField, .secureTextField, .textView]
            where matches.contains(candidate)
        {
            return candidate
        }
        return nil
    }

    private static func preferredAccountNavigationTarget(
        macOSOutlineRow: Bool,
        tabBarButton: Bool,
        fallbackText: Bool
    ) -> AccountNavigationTarget? {
        // On macOS, tapping the child StaticText does not select its List row.
        // Prefer the containing outline cell whenever it is available.
        if macOSOutlineRow { return .macOSOutlineRow }
        if tabBarButton { return .tabBarButton }
        if fallbackText { return .fallbackText }
        return nil
    }

    private static func postAuthDestination(
        connect: Bool,
        verification: Bool,
        welcome: Bool,
        welcomeActionable: Bool = true,
        introduction: Bool = false,
        closeOverlay: Bool = false,
        closeOverlayActionable: Bool = true
    ) -> PostAuthDestination {
        // Verification wins if two views briefly overlap during a transition:
        // configured acceptance identities must never silently pass through it.
        if verification { return .verification }
        // The main Connect view remains discoverable behind this modal sheet.
        // Complete onboarding before treating that covered control as usable.
        if introduction { return .introduction }
        if closeOverlay { return closeOverlayActionable ? .overlay : .pending }
        if connect { return .connect }
        if welcome { return welcomeActionable ? .welcome : .pending }
        return .pending
    }

    private static func revealUntilExists(
        maxSwipes: Int,
        waitForInitialExistence: () -> Bool,
        exists: () -> Bool,
        swipe: () -> Bool
    ) -> Bool {
        // NavigationLink removes one page before the destination accessibility
        // tree is ready. Give that transition time to settle before attempting
        // a gesture against a sheet with no hittable content yet.
        if waitForInitialExistence() || exists() { return true }
        for _ in 0..<maxSwipes {
            guard swipe() else { return false }
            if exists() { return true }
        }
        return false
    }

    private static func preferredScrollCandidateIndex(
        _ candidates: [ScrollCandidateState]
    ) -> Int? {
        if let requested = candidates.indices.first(where: {
            candidates[$0].requested && candidates[$0].hittable && candidates[$0].area > 0
        }) {
            return requested
        }

        return candidates.indices
            .filter { candidates[$0].hittable && candidates[$0].area > 0 }
            .max { candidates[$0].area < candidates[$1].area }
    }

    private static func preferredInterruptionCandidateIndex(
        _ candidates: [InterruptionCandidateState]
    ) -> Int? {
        // XCUIApplication has no hit point on macOS even while its window is
        // visible. An interruption monitor must be provoked through a named
        // app-owned element instead. Do not require that element to be
        // hittable: a system permission sheet is precisely what may cover it.
        candidates.indices.first(where: {
            !candidates[$0].applicationRoot && candidates[$0].exists
        })
    }

    private static func vpnAuthorizationAction(
        systemDialogExists: Bool,
        recognizedVPNPromptExists: Bool,
        interruptionTriggerExists: Bool
    ) -> VPNAuthorizationAction {
        // On macOS, NetworkExtension authorization is owned by
        // UserNotificationCenter, not the app under test. Tapping an uncovered
        // app control never invokes an XCTest interruption monitor, so address
        // the system prompt directly whenever it is present.
        if recognizedVPNPromptExists {
            return .tapSystemAllow
        }
        if systemDialogExists {
            return .failUnrecognizedSystemPrompt
        }
        return interruptionTriggerExists
            ? .triggerInterruptionMonitor
            : .failMissingTrigger
    }

    private static func preferredVPNAuthorizationDialogIndex(
        _ candidates: [VPNAuthorizationDialogState]
    ) -> Int? {
        // The macOS VPN prompt heading is exposed through AXValue rather than
        // AXLabel. Identify the prompt by its dialog-scoped authorization
        // actions so a heading query cannot silently miss the live prompt.
        candidates.indices.first(where: {
            candidates[$0].exists
                && candidates[$0].allowActionExists
                && candidates[$0].denyActionExists
        })
    }

    private static func connectedStatusLabel(in labels: [String]) -> String? {
        labels.first(where: { $0.hasPrefix(connectedStatusPrefix) })
    }

    private static func controlActionable(
        exists: Bool,
        cooldownElapsed: Bool,
        enabled: () -> Bool
    ) -> Bool {
        exists && cooldownElapsed && enabled()
    }

    private static func transitionControlState(
        retryReady: Bool,
        exists: () -> Bool,
        enabled: () -> Bool
    ) -> TransitionControlState {
        guard retryReady else {
            return TransitionControlState(exists: false, actionable: false)
        }
        let controlExists = exists()
        return TransitionControlState(
            exists: controlExists,
            actionable: controlExists && enabled()
        )
    }

    private static func accessibilityText(
        label: String,
        value: Any?
    ) -> String {
        if !label.isEmpty { return label }
        return value as? String ?? ""
    }

    private struct SignupInputs {
        let networkPrefix: String
        let password: String
        let emailDomain: String
        let emailPrefix: String
        let phoneNumber: String
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    func testPostAuthDestinationRecognizesWelcomeGate() {
        XCTAssertEqual(
            Self.postAuthDestination(connect: false, verification: false, welcome: true),
            .welcome
        )
        XCTAssertEqual(
            Self.postAuthDestination(
                connect: false,
                verification: false,
                welcome: true,
                welcomeActionable: false
            ),
            .pending,
            "a disabled or cooling-down welcome control must not be tapped"
        )
        XCTAssertEqual(
            Self.postAuthDestination(connect: true, verification: true, welcome: false),
            .verification
        )
        XCTAssertEqual(
            Self.postAuthDestination(
                connect: true,
                verification: false,
                welcome: false,
                introduction: true
            ),
            .introduction,
            "modal onboarding must win over the covered Connect control"
        )
        XCTAssertEqual(
            Self.postAuthDestination(
                connect: true,
                verification: false,
                welcome: false,
                closeOverlay: true
            ),
            .overlay,
            "a post-auth overlay must be dismissed before using controls behind it"
        )
    }

    func testRevealUntilExistsSearchesLazyScrollContentAndIsBounded() {
        var swipes = 0
        XCTAssertTrue(
            Self.revealUntilExists(
                maxSwipes: 8,
                waitForInitialExistence: { false },
                exists: { swipes == 3 },
                swipe: {
                    swipes += 1
                    return true
                }
            )
        )
        XCTAssertEqual(swipes, 3)

        swipes = 0
        XCTAssertFalse(
            Self.revealUntilExists(
                maxSwipes: 4,
                waitForInitialExistence: { false },
                exists: { false },
                swipe: {
                    swipes += 1
                    return true
                }
            )
        )
        XCTAssertEqual(swipes, 4)

        var existenceProbes = 0
        swipes = 0
        XCTAssertTrue(
            Self.revealUntilExists(
                maxSwipes: 4,
                waitForInitialExistence: { true },
                exists: {
                    existenceProbes += 1
                    return false
                },
                swipe: {
                    swipes += 1
                    return true
                }
            )
        )
        XCTAssertEqual(existenceProbes, 0)
        XCTAssertEqual(swipes, 0, "a navigation destination must settle before scrolling")
    }

    func testScrollSelectionUsesTheRequestedContainerInsteadOfTheApplicationRoot() {
        let candidates = [
            ScrollCandidateState(requested: false, hittable: false, area: 1024 * 768),
            ScrollCandidateState(requested: false, hittable: true, area: 140 * 708),
            ScrollCandidateState(requested: true, hittable: true, area: 876 * 716),
        ]
        XCTAssertEqual(Self.preferredScrollCandidateIndex(candidates), 2)

        let withoutIdentifier = [
            ScrollCandidateState(requested: false, hittable: true, area: 140 * 708),
            ScrollCandidateState(requested: false, hittable: true, area: 876 * 716),
        ]
        XCTAssertEqual(
            Self.preferredScrollCandidateIndex(withoutIdentifier),
            1,
            "the content scroll view must win over the smaller sidebar"
        )
    }

    func testRevealStopsWhenNoScrollContainerCanReceiveTheGesture() {
        var attempts = 0
        XCTAssertFalse(
            Self.revealUntilExists(
                maxSwipes: 8,
                waitForInitialExistence: { false },
                exists: { false },
                swipe: {
                    attempts += 1
                    return false
                }
            )
        )
        XCTAssertEqual(attempts, 1)
    }

    func testInterruptionTriggerNeverUsesTheApplicationRoot() {
        let coveredStatus = [
            InterruptionCandidateState(applicationRoot: true, exists: true),
            InterruptionCandidateState(applicationRoot: false, exists: true),
        ]
        XCTAssertEqual(Self.preferredInterruptionCandidateIndex(coveredStatus), 1)

        XCTAssertNil(
            Self.preferredInterruptionCandidateIndex([
                InterruptionCandidateState(applicationRoot: true, exists: true),
                InterruptionCandidateState(applicationRoot: false, exists: false),
            ]),
            "the macOS application root must never be used as an interaction target"
        )
    }

    func testMacOSVPNAuthorizationUsesTheSystemOwnedPrompt() {
        XCTAssertEqual(
            Self.vpnAuthorizationAction(
                systemDialogExists: true,
                recognizedVPNPromptExists: true,
                interruptionTriggerExists: true
            ),
            .tapSystemAllow,
            "the UserNotificationCenter prompt must win over an uncovered app control"
        )
        XCTAssertEqual(
            Self.vpnAuthorizationAction(
                systemDialogExists: true,
                recognizedVPNPromptExists: false,
                interruptionTriggerExists: true
            ),
            .failUnrecognizedSystemPrompt,
            "an unrecognized system prompt must fail visibly instead of silently timing out"
        )
        XCTAssertEqual(
            Self.vpnAuthorizationAction(
                systemDialogExists: false,
                recognizedVPNPromptExists: false,
                interruptionTriggerExists: true
            ),
            .triggerInterruptionMonitor
        )
    }

    func testMacOSVPNAuthorizationDoesNotDependOnHeadingLabel() {
        let unrelatedDialog = VPNAuthorizationDialogState(
            exists: true,
            allowActionExists: false,
            denyActionExists: false
        )
        let valueOnlyHeadingPrompt = VPNAuthorizationDialogState(
            exists: true,
            allowActionExists: true,
            denyActionExists: true
        )

        XCTAssertEqual(
            Self.preferredVPNAuthorizationDialogIndex([
                unrelatedDialog,
                valueOnlyHeadingPrompt,
            ]),
            1,
            "the action structure must identify a prompt whose heading has no AXLabel"
        )
        XCTAssertNil(
            Self.preferredVPNAuthorizationDialogIndex([
                VPNAuthorizationDialogState(
                    exists: true,
                    allowActionExists: true,
                    denyActionExists: false
                ),
            ]),
            "a partial or changed authorization prompt must not be approved"
        )
    }

    func testConnectedStatusIgnoresPropagatedIconIdentifiers() {
        XCTAssertEqual(
            Self.connectedStatusLabel(in: [
                "GlobeMask",
                "Connected to 8 providers",
                "Forward",
            ]),
            "Connected to 8 providers"
        )
        XCTAssertNil(Self.connectedStatusLabel(in: ["GlobeMask", "Forward"]))
    }

    func testMissingOrCoolingDownControlDoesNotProbeEnabledState() {
        var enabledProbes = 0
        let enabled = {
            enabledProbes += 1
            return true
        }
        XCTAssertFalse(
            Self.controlActionable(exists: false, cooldownElapsed: true, enabled: enabled)
        )
        XCTAssertFalse(
            Self.controlActionable(exists: true, cooldownElapsed: false, enabled: enabled)
        )
        XCTAssertEqual(enabledProbes, 0)
        XCTAssertTrue(
            Self.controlActionable(exists: true, cooldownElapsed: true, enabled: enabled)
        )
        XCTAssertEqual(enabledProbes, 1)
    }

    func testTransitionGraceDoesNotQueryDepartingControl() {
        var existenceProbes = 0
        var enabledProbes = 0
        let coolingDown = Self.transitionControlState(
            retryReady: false,
            exists: {
                existenceProbes += 1
                return true
            },
            enabled: {
                enabledProbes += 1
                return true
            }
        )
        XCTAssertFalse(coolingDown.exists)
        XCTAssertFalse(coolingDown.actionable)
        XCTAssertEqual(existenceProbes, 0, "a departing XCUIElement must not be queried")
        XCTAssertEqual(enabledProbes, 0, "a stale enabled-state lookup can abort XCTest")

        let ready = Self.transitionControlState(
            retryReady: true,
            exists: {
                existenceProbes += 1
                return true
            },
            enabled: {
                enabledProbes += 1
                return true
            }
        )
        XCTAssertTrue(ready.exists)
        XCTAssertTrue(ready.actionable)
        XCTAssertEqual(existenceProbes, 1)
        XCTAssertEqual(enabledProbes, 1)
    }

    func testInputSelectionIgnoresDecorativeIdentifierMatches() {
        XCTAssertEqual(
            Self.preferredInputElementKind([.nonEditable, .textView]),
            .textView,
            "a placeholder label must not win over its editable text view"
        )
        XCTAssertNil(
            Self.preferredInputElementKind([.nonEditable]),
            "an identifier on only non-editable content is not a usable input"
        )
    }

    func testAccountNavigationSelectsMacOSOutlineRowInsteadOfAmbiguousText() {
        XCTAssertEqual(
            Self.preferredAccountNavigationTarget(
                macOSOutlineRow: true,
                tabBarButton: false,
                fallbackText: true
            ),
            .macOSOutlineRow,
            "the sidebar row must win over its non-selecting Account text child"
        )
        XCTAssertEqual(
            Self.preferredAccountNavigationTarget(
                macOSOutlineRow: false,
                tabBarButton: true,
                fallbackText: true
            ),
            .tabBarButton
        )
    }

    func testAccessibilityTextUsesExplicitLabel() {
        XCTAssertEqual(
            Self.accessibilityText(label: "current", value: "fallback"),
            "current"
        )
    }

    func testAccessibilityTextFallsBackWhenMacOSLeavesLabelEmpty() {
        XCTAssertEqual(
            Self.accessibilityText(label: "", value: "20260829-test-macos"),
            "20260829-test-macos"
        )
        XCTAssertEqual(Self.accessibilityText(label: "", value: nil), "")
    }

    @MainActor
    func testColdProcessRelaunchRestoresSecureTunnelCredentials() throws {
        #if os(iOS)
        let runId = UUID().uuidString
        app.launchEnvironment["UR_COLD_RELAUNCH_MODE"] = "seed"
        app.launchEnvironment["UR_COLD_RELAUNCH_RUN_ID"] = runId
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
        let seeded = element("integration.cold-relaunch.result")
        XCTAssertTrue(seeded.waitForExistence(timeout: 30))
        XCTAssertEqual(seeded.label, "seeded")

        // XCUIApplication.terminate kills the target process. The next launch
        // creates a new DeviceManager/app process and can recover only from
        // durable Keychain material, not Swift/static memory.
        app.terminate()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 30))

        app = XCUIApplication()
        app.launchEnvironment["UR_COLD_RELAUNCH_MODE"] = "verify"
        app.launchEnvironment["UR_COLD_RELAUNCH_RUN_ID"] = runId
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
        let verified = element("integration.cold-relaunch.result")
        XCTAssertTrue(verified.waitForExistence(timeout: 30))
        XCTAssertEqual(verified.label, "verified")
        #endif
    }

    @MainActor
    func testMainAcceptance() throws {
        let environment = ProcessInfo.processInfo.environment
        let user = try requiredEnvironment("UR_ACCEPT_USER", environment)
        let password = try requiredEnvironment("UR_ACCEPT_PASS", environment)
        let expectedBuildID = try requiredEnvironment("UR_ACCEPT_BUILD_ID", environment)
        let platform = try requiredEnvironment("UR_ACCEPT_PLATFORM", environment)
        let signup = SignupInputs(
            networkPrefix: try requiredEnvironment("UR_ACCEPT_SIGNUP_NETWORK_PREFIX", environment),
            password: try requiredEnvironment("UR_ACCEPT_SIGNUP_PASSWORD", environment),
            emailDomain: try requiredEnvironment("UR_ACCEPT_SIGNUP_EMAIL_DOMAIN", environment),
            emailPrefix: try requiredEnvironment("UR_ACCEPT_SIGNUP_EMAIL_PREFIX", environment),
            phoneNumber: try requiredEnvironment("UR_ACCEPT_SIGNUP_PHONE", environment)
        )
        let repetitions = Int(environment["UR_ACCEPT_REPEAT"] ?? "1") ?? 0
        XCTAssertGreaterThan(repetitions, 0, "UR_ACCEPT_REPEAT must be positive")
        XCTAssertTrue(platform == "ios" || platform == "macos")
        let peerProviderID: String?
        if platform == "macos" {
            peerProviderID = try requiredEnvironment("UR_ACCEPT_PEER_ID", environment)
        } else {
            peerProviderID = nil
        }

        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
        let marker = element("acceptance.build.id")
        XCTAssertTrue(marker.waitForExistence(timeout: 30), "local-build marker is missing")
        XCTAssertEqual(
            Self.accessibilityText(label: marker.label, value: marker.value),
            expectedBuildID,
            "a stale app is running"
        )
        let environmentMarker = element("acceptance.environment")
        XCTAssertTrue(environmentMarker.waitForExistence(timeout: 30), "environment marker is missing")
        XCTAssertEqual(
            Self.accessibilityText(
                label: environmentMarker.label,
                value: environmentMarker.value
            ),
            "main",
            "acceptance app is not targeting main"
        )

        try ensureLoggedOut()
        var secretKey = normalizedSecret(environment["UR_ACCEPT_SECRET"])

        for current in 1...repetitions {
            repetition = current
            print("UR_ACCEPTANCE_BEGIN repetition=\(current)/\(repetitions) platform=\(platform)")
            do {
                let unique = "\(platform)-\(current)-\(Int(Date().timeIntervalSince1970 * 1_000))"
                let email = "\(signup.emailPrefix)-\(unique)@\(signup.emailDomain)".lowercased()
                try passwordSignupLifecycle(
                    method: "email", userAuth: email, signup: signup, unique: unique
                )
                try passwordSignupLifecycle(
                    method: "phone", userAuth: signup.phoneNumber, signup: signup, unique: unique
                )

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
                    try connectAndVerifyPeer(try XCTUnwrap(peerProviderID))
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

    private func inputElement(
        _ identifier: String,
        timeout: TimeInterval
    ) -> XCUIElement? {
        let textField = app.textFields[identifier].firstMatch
        let secureTextField = app.secureTextFields[identifier].firstMatch
        let textView = app.textViews[identifier].firstMatch
        let anyMatch = element(identifier)
        let deadline = Date().addingTimeInterval(timeout)

        repeat {
            var matches: [InputElementKind] = []
            if textField.exists { matches.append(.textField) }
            if secureTextField.exists { matches.append(.secureTextField) }
            if textView.exists { matches.append(.textView) }
            if anyMatch.exists { matches.append(.nonEditable) }

            switch Self.preferredInputElementKind(matches) {
            case .textField:
                return textField
            case .secureTextField:
                return secureTextField
            case .textView:
                return textView
            case .nonEditable, .none:
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            }
        } while Date() < deadline

        return nil
    }

    private func swipe(
        _ direction: ScrollDirection,
        in requestedIdentifier: String? = nil
    ) -> Bool {
        #if os(macOS)
        var elements: [XCUIElement] = []
        var candidates: [ScrollCandidateState] = []
        if let requestedIdentifier {
            let requested = element(requestedIdentifier)
            let frame = requested.frame
            elements.append(requested)
            candidates.append(ScrollCandidateState(
                requested: true,
                hittable: requested.exists && requested.isHittable,
                area: max(0, frame.width) * max(0, frame.height)
            ))
        }
        for scrollView in app.scrollViews.allElementsBoundByIndex {
            let frame = scrollView.frame
            elements.append(scrollView)
            candidates.append(ScrollCandidateState(
                requested: false,
                hittable: scrollView.exists && scrollView.isHittable,
                area: max(0, frame.width) * max(0, frame.height)
            ))
        }
        guard let index = Self.preferredScrollCandidateIndex(candidates) else {
            return false
        }
        switch direction {
        case .up:
            elements[index].swipeUp()
        case .down:
            elements[index].swipeDown()
        }
        return true
        #else
        if let requestedIdentifier {
            let requested = element(requestedIdentifier)
            if requested.exists && requested.isHittable {
                switch direction {
                case .up:
                    requested.swipeUp()
                case .down:
                    requested.swipeDown()
                }
                return true
            }
        }
        switch direction {
        case .up:
            app.swipeUp()
        case .down:
            app.swipeDown()
        }
        return true
        #endif
    }

    private func tap(
        _ identifier: String,
        timeout: TimeInterval = 30,
        scrollContainer: String? = nil
    ) throws {
        let target = element(identifier)
        XCTAssertTrue(target.waitForExistence(timeout: timeout), "missing UI control \(identifier)")
        for _ in 0..<8 where !target.isHittable {
            guard swipe(.up, in: scrollContainer) else { break }
        }
        XCTAssertTrue(target.isHittable, "UI control is not hittable: \(identifier)")
        target.tap()
    }

    private func revealAndTap(
        _ identifier: String,
        maxSwipes: Int = 12,
        scrollContainer: String? = nil
    ) throws {
        let target = element(identifier)
        XCTAssertTrue(
            Self.revealUntilExists(
                maxSwipes: maxSwipes,
                waitForInitialExistence: { target.waitForExistence(timeout: 10) },
                exists: { target.exists },
                swipe: { self.swipe(.up, in: scrollContainer) }
            ),
            "missing lazy scroll control \(identifier)"
        )
        try tap(identifier, scrollContainer: scrollContainer)
    }

    private func enter(_ value: String, in identifier: String) throws {
        guard let field = inputElement(identifier, timeout: 30) else {
            XCTFail("missing editable input \(identifier)")
            throw AcceptanceError.unexpectedInitialState
        }
        for _ in 0..<8 where !field.isHittable {
            guard swipe(.up) else { break }
        }
        field.tap()
        #if os(macOS)
        field.typeKey("a", modifierFlags: .command)
        #endif
        field.typeText(value)
    }

    private func waitForMain() throws {
        let deadline = Date().addingTimeInterval(90)
        var welcomeNextAttempt = Date.distantPast
        var closeOverlayNextAttempt = Date.distantPast
        repeat {
            let now = Date()
            let enter = element("acceptance.welcome.enter")
            let close = app.buttons["Close"].firstMatch
            let welcomeState = Self.transitionControlState(
                retryReady: now >= welcomeNextAttempt,
                exists: { enter.exists },
                enabled: { enter.isEnabled }
            )
            let closeState = Self.transitionControlState(
                retryReady: now >= closeOverlayNextAttempt,
                exists: { close.exists },
                enabled: { close.isEnabled }
            )
            let destination = Self.postAuthDestination(
                connect: element("acceptance.connect").exists,
                verification: element("acceptance.verify.code").exists,
                welcome: welcomeState.exists,
                welcomeActionable: welcomeState.actionable,
                introduction: introductionIsVisible(),
                closeOverlay: closeState.exists,
                closeOverlayActionable: closeState.actionable
            )
            switch destination {
            case .connect:
                return
            case .verification:
                XCTFail("configured acceptance identity unexpectedly requires verification")
                throw AcceptanceError.unexpectedInitialState
            case .introduction:
                try completeIntroduction()
            case .welcome:
                let frame = enter.frame
                if !frame.isEmpty, enter.isHittable {
                    // A tap can be dropped while the welcome animation settles,
                    // while a successful transition can leave an invalid stale
                    // accessibility node. Cool down before retrying and check a
                    // valid frame before asking XCTest for hittability.
                    welcomeNextAttempt = now.addingTimeInterval(Self.transitionRetryDelay)
                    enter.tap()
                }
            case .overlay:
                let frame = close.frame
                if !frame.isEmpty, close.isHittable {
                    closeOverlayNextAttempt = now.addingTimeInterval(Self.transitionRetryDelay)
                    close.tap()
                }
            case .pending:
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline
        XCTFail("main Connect screen did not become ready")
        throw AcceptanceError.unexpectedInitialState
    }

    private func completeIntroduction() throws {
        print("UR_ACCEPTANCE_STEP complete-introduction")
        let stages = [
            "acceptance.introduction.community",
            "acceptance.introduction.usage.continue",
            "acceptance.introduction.provide.continue",
            "acceptance.introduction.finish",
        ]
        guard let current = stages.firstIndex(where: { element($0).exists }) else {
            XCTFail("introduction was detected without a recoverable stage")
            throw AcceptanceError.unexpectedInitialState
        }
        for identifier in stages[current...] {
            try revealAndTap(identifier)
        }
    }

    private func introductionIsVisible() -> Bool {
        for identifier in [
            "acceptance.introduction.community",
            "acceptance.introduction.usage.continue",
            "acceptance.introduction.provide.continue",
            "acceptance.introduction.finish",
        ] where element(identifier).exists {
            return true
        }
        return false
    }

    private func waitUntilEnabled(_ identifier: String, timeout: TimeInterval = 90) throws {
        let target = element(identifier)
        XCTAssertTrue(target.waitForExistence(timeout: timeout), "missing UI control \(identifier)")
        let enabled = NSPredicate(format: "enabled == true")
        let expectation = XCTNSPredicateExpectation(predicate: enabled, object: target)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed, "UI control never enabled: \(identifier)")
    }

    private func turnOnSwitch(_ identifier: String) throws {
        let target = element(identifier)
        XCTAssertTrue(target.waitForExistence(timeout: 30), "missing switch \(identifier)")
        for _ in 0..<8 where !target.isHittable {
            guard swipe(.up) else { break }
        }
        XCTAssertTrue(target.isHittable, "switch is not hittable: \(identifier)")

        let isOn = NSPredicate { object, _ in
            guard let element = object as? XCUIElement else { return false }
            if let value = element.value as? NSNumber { return value.boolValue }
            guard let value = element.value as? String else { return false }
            return value == "1" || value.caseInsensitiveCompare("on") == .orderedSame
        }
        if !isOn.evaluate(with: target) {
            // UrSwitchToggle exposes its complete label as one accessibility row,
            // A plain XCUIElement.tap() lands in the label and leaves the switch off.
            target.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        }

        let expectation = XCTNSPredicateExpectation(predicate: isOn, object: target)
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: 5),
            .completed,
            "switch did not turn on: \(identifier)"
        )
    }

    private func waitForEither(_ first: String, _ second: String, timeout: TimeInterval = 90) throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if element(first).exists { return first }
            if element(second).exists { return second }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline
        XCTFail("neither UI control appeared: \(first), \(second)")
        throw AcceptanceError.unexpectedInitialState
    }

    private func completePasswordPrompt(password: String) throws {
        try enter(password, in: "acceptance.password.input")
        try tap("acceptance.password.submit")
        try waitForMain()
    }

    private func openNewPasswordSignup(userAuth: String, signup: SignupInputs) throws {
        for attempt in 0..<2 {
            try enter(userAuth, in: "acceptance.password.user")
            try tap("acceptance.password.next")
            let destination = try waitForEither("acceptance.create.network", "acceptance.password.input")
            if destination == "acceptance.create.network" { return }

            // A configured fixture can survive an interrupted campaign.
            // Authenticate and delete only that dedicated identity, then retry.
            try completePasswordPrompt(password: signup.password)
            try deleteAccountThroughUI()
            if attempt == 1 {
                XCTFail("dedicated password fixture could not be reset")
                throw AcceptanceError.unexpectedInitialState
            }
        }
    }

    private func passwordSignupLifecycle(
        method: String,
        userAuth: String,
        signup: SignupInputs,
        unique: String
    ) throws {
        print("UR_ACCEPTANCE_STEP signup-\(method)")
        try openNewPasswordSignup(userAuth: userAuth, signup: signup)
        let network = "\(signup.networkPrefix)-\(method)-\(unique)"
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        try enter(String(network.prefix(49)), in: "acceptance.create.network")
        try enter(signup.password, in: "acceptance.create.password")
        try turnOnSwitch("acceptance.create.terms")
        try waitUntilEnabled("acceptance.create.submit")
        try tap("acceptance.create.submit", timeout: 90)
        try waitForMain()
        let networkID = try currentNetworkID()
        attachScreenshot("\(repetition)-\(method)-signup")
        do {
            try logoutThroughUI()
            try loginWithPassword(user: userAuth, password: signup.password)
            XCTAssertEqual(try currentNetworkID(), networkID, "\(method) login returned a different network")
            attachScreenshot("\(repetition)-\(method)-login")
            try deleteAccountThroughUI()
        } catch {
            try? deleteAccountThroughUI()
            throw error
        }
    }

    private func deleteAccountThroughUI() throws {
        print("UR_ACCEPTANCE_STEP delete-temporary-account")
        if element("acceptance.password.user").exists { return }
        try navigateToAccount()
        try tap("acceptance.account.settings")
        try revealAndTap(
            "acceptance.account.delete.request",
            scrollContainer: "acceptance.account.settings.scroll"
        )
        let confirm = element("acceptance.account.delete.confirm")
        if confirm.waitForExistence(timeout: 10) {
            confirm.tap()
        } else {
            let fallback = app.buttons["Delete account"]
            XCTAssertTrue(fallback.waitForExistence(timeout: 10), "delete-account confirmation is missing")
            fallback.tap()
        }
        XCTAssertTrue(
            element("acceptance.password.user").waitForExistence(timeout: 90),
            "login screen did not return after account deletion"
        )
    }

    private func currentNetworkID() throws -> String {
        let marker = element("acceptance.network.id")
        XCTAssertTrue(marker.waitForExistence(timeout: 30), "authenticated app exposed no network ID")
        let networkID = Self.accessibilityText(label: marker.label, value: marker.value)
        guard !networkID.isEmpty else {
            XCTFail("authenticated app exposed an empty network ID")
            throw AcceptanceError.unexpectedInitialState
        }
        return networkID
    }

    private func currentClientID() throws -> String {
        let marker = element("acceptance.client.id")
        XCTAssertTrue(marker.waitForExistence(timeout: 30), "authenticated app exposed no client ID")
        let clientID = Self.accessibilityText(label: marker.label, value: marker.value)
        guard !clientID.isEmpty else {
            XCTFail("authenticated app exposed an empty client ID")
            throw AcceptanceError.unexpectedInitialState
        }
        return clientID
    }

    private func createInstantAccount() throws -> String {
        print("UR_ACCEPTANCE_STEP create-instant-account")
        try tap("acceptance.login.instant")
        try turnOnSwitch("acceptance.instant.terms")
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
        #if os(macOS)
        let accountOutlineRow: XCUIElement? = app.outlines.cells
            .containing(.staticText, identifier: "Account")
            .firstMatch
        #else
        let accountOutlineRow: XCUIElement? = nil
        #endif
        let accountTab = app.tabBars.buttons["Account"].firstMatch
        let accountText = app.staticTexts["Account"].firstMatch
        switch Self.preferredAccountNavigationTarget(
            macOSOutlineRow: accountOutlineRow?.exists == true,
            tabBarButton: accountTab.exists,
            fallbackText: accountText.exists
        ) {
        case .macOSOutlineRow:
            try XCTUnwrap(accountOutlineRow).tap()
        case .tabBarButton:
            accountTab.tap()
        case .fallbackText:
            accountText.tap()
        case .none:
            XCTFail("Account navigation is missing")
            throw AcceptanceError.unexpectedInitialState
        }
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
            // A retained post-signup session can expose Connect behind the
            // introduction sheet. Normalize that modal state before logout.
            try waitForMain()
            try logoutThroughUI()
            return
        }
        XCTFail("app did not reach either login or main UI")
        throw AcceptanceError.unexpectedInitialState
    }

    private func recoverToLoggedOut() throws {
        if introductionIsVisible() {
            try waitForMain()
        }
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
        try authorizeVPNConfigurationIfRequested(
            using: "acceptance.connect.status"
        )
        XCTAssertTrue(
            connectedStatusElement().waitForExistence(timeout: 120),
            "Connect never exposed its connected accessibility status"
        )
        XCTAssertTrue(element("acceptance.disconnect").waitForExistence(timeout: 30))
        attachScreenshot("\(repetition)-connected")

        let after = try publicIP()
        print("UR_ACCEPTANCE_STEP egress-after=\(after)")
        XCTAssertNotEqual(before, after, "public IP did not change after Connect")

        try tap("acceptance.disconnect")
        XCTAssertTrue(element("acceptance.connect").waitForExistence(timeout: 90))
        attachScreenshot("\(repetition)-disconnected")
    }

    private func connectAndVerifyPeer(_ peerProviderID: String) throws {
        print("UR_ACCEPTANCE_STEP peer-to-peer")
        try tap(
            "acceptance.peers.open",
            scrollContainer: "acceptance.connect.scroll"
        )
        let peer = element("acceptance.peer.\(peerProviderID)")
        XCTAssertTrue(
            peer.waitForExistence(timeout: 180),
            "controlled same-network peer did not become discoverable"
        )
        for _ in 0..<8 where !peer.isHittable {
            guard swipe(.down, in: "acceptance.provider.list") else { break }
        }
        XCTAssertTrue(peer.isHittable, "controlled same-network peer is not hittable")
        peer.tap()
        XCTAssertTrue(
            connectedStatusElement().waitForExistence(timeout: 120),
            "peer connection never exposed its connected accessibility status"
        )
        XCTAssertTrue(element("acceptance.disconnect").waitForExistence(timeout: 30))

        let address = try publicIP()
        XCTAssertFalse(address.isEmpty, "peer request returned no public address")
        print("UR_ACCEPTANCE_P2P_PASS repetition=\(repetition) peer=controlled")
        attachScreenshot("\(repetition)-peer-to-peer")

        try tap("acceptance.disconnect")
        XCTAssertTrue(element("acceptance.connect").waitForExistence(timeout: 90))
    }

    private func authorizeVPNConfigurationIfRequested(
        using interruptionIdentifier: String
    ) throws {
        let triggerExists = element(interruptionIdentifier)
            .waitForExistence(timeout: 30)

        #if os(macOS)
        let systemUI = XCUIApplication(
            bundleIdentifier: "com.apple.UserNotificationCenter"
        )
        let systemDialogExists = systemUI.dialogs.firstMatch
            .waitForExistence(timeout: 10)
        let dialogs = systemUI.dialogs.allElementsBoundByIndex
        let dialogStates = dialogs.map { dialog in
            VPNAuthorizationDialogState(
                exists: dialog.exists,
                allowActionExists: dialog.buttons["action-button-2"]
                    .firstMatch.waitForExistence(timeout: 2),
                denyActionExists: dialog.buttons["action-button-1"]
                    .firstMatch.waitForExistence(timeout: 2)
            )
        }
        let vpnDialogIndex = Self.preferredVPNAuthorizationDialogIndex(
            dialogStates
        )

        switch Self.vpnAuthorizationAction(
            systemDialogExists: systemDialogExists,
            recognizedVPNPromptExists: vpnDialogIndex != nil,
            interruptionTriggerExists: triggerExists
        ) {
        case .tapSystemAllow:
            guard let vpnDialogIndex else {
                XCTFail("recognized macOS VPN prompt has no dialog")
                throw AcceptanceError.unexpectedInitialState
            }
            let vpnPrompt = dialogs[vpnDialogIndex]
            let allow = vpnPrompt.buttons["action-button-2"].firstMatch
            allow.tap()
            XCTAssertFalse(
                vpnPrompt.waitForExistence(timeout: 10),
                "macOS retained the VPN authorization prompt after Allow"
            )
            return
        case .failUnrecognizedSystemPrompt:
            XCTFail(
                "macOS exposed a system dialog without the expected VPN authorization actions"
            )
            throw AcceptanceError.unexpectedInitialState
        case .triggerInterruptionMonitor:
            try triggerInterruptionMonitor(using: interruptionIdentifier)
            return
        case .failMissingTrigger:
            XCTFail("missing interruption-monitor target \(interruptionIdentifier)")
            throw AcceptanceError.unexpectedInitialState
        }
        #else
        switch Self.vpnAuthorizationAction(
            systemDialogExists: false,
            recognizedVPNPromptExists: false,
            interruptionTriggerExists: triggerExists
        ) {
        case .triggerInterruptionMonitor:
            try triggerInterruptionMonitor(using: interruptionIdentifier)
        case .tapSystemAllow, .failUnrecognizedSystemPrompt, .failMissingTrigger:
            XCTFail("missing interruption-monitor target \(interruptionIdentifier)")
            throw AcceptanceError.unexpectedInitialState
        }
        #endif
    }

    private func triggerInterruptionMonitor(using identifier: String) throws {
        let application = try XCTUnwrap(app)
        let requested = element(identifier)
        let requestedExists = requested.waitForExistence(timeout: 30)
        let elements = [application, requested]
        let candidates = [
            InterruptionCandidateState(applicationRoot: true, exists: application.exists),
            InterruptionCandidateState(applicationRoot: false, exists: requestedExists),
        ]
        guard let index = Self.preferredInterruptionCandidateIndex(candidates) else {
            XCTFail("missing interruption-monitor target \(identifier)")
            throw AcceptanceError.unexpectedInitialState
        }
        elements[index].tap()
    }

    private func connectedStatusElement() -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: "acceptance.connect.status")
            .matching(NSPredicate(
                format: "label BEGINSWITH %@",
                Self.connectedStatusPrefix
            ))
            .firstMatch
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
