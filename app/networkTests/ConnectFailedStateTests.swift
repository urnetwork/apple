//
//  ConnectFailedStateTests.swift
//  networkTests
//
//  The connect view shows the sdk's CONNECT_FAILED the way the Windows,
//  Linux and Android apps do: "Couldn't connect" with the coral indicator,
//  the warning in place of the provider grid, and Retry beside Disconnect.
//  Retry runs the drawer's connect again, which the sdk rebuilds; it is not
//  offered out of balance or while the tunnel itself needs reconnecting.
//

import Foundation
import Testing
import URnetworkSdk
@testable import URnetwork

@MainActor
struct ConnectFailedStateTests {

    // every other status, and none yet
    private static let otherStatuses: [ConnectionStatus?] = [.disconnected, .connecting, .destinationSet, .connected, nil]

    private static func indicator(
        _ status: ConnectionStatus?,
        insufficientBalance: Bool = false,
        currentPlan: Plan = .none
    ) -> ConnectStatusIndicator {
        let contractStatus = SdkContractStatus()
        contractStatus.insufficientBalance = insufficientBalance
        return ConnectStatusIndicator(
            connectionStatus: status,
            displayReconnectTunnel: false,
            contractStatus: contractStatus,
            windowCurrentSize: 0,
            isPollingSubscriptionBalance: false,
            currentPlan: currentPlan
        )
    }

    // …/apple/app/networkTests/ConnectFailedStateTests.swift -> …/apple/app
    private static let appRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static func source(_ path: String) throws -> String {
        try String(contentsOf: appRoot.appendingPathComponent(path), encoding: .utf8)
    }

    // MARK: the status

    @Test func connectFailedIsItsOwnStatus() {
        #expect(ConnectionStatus(rawValue: SdkConnectFailed) == .connectFailed)
        #expect(ConnectionStatus.connectFailed.rawValue == SdkConnectFailed)
    }

    // MARK: the status line

    @Test func theStatusLineSaysCouldNotConnectWithTheCoralIndicator() {
        for plan in [Plan.none, .supporter] {
            let failed = Self.indicator(.connectFailed, currentPlan: plan)
            #expect(failed.statusMsg == String(localized: "Couldn't connect"))
            #expect(failed.statusMsg != String(localized: "Connecting to providers"))
            // UrCoral (#FF6C58), the desktop apps' kUrCoral
            #expect(failed.statusMsgIconColor == .urCoral)
        }
        // a supporter connects out of balance, so the failure is what shows
        let supporter = Self.indicator(.connectFailed, insufficientBalance: true, currentPlan: .supporter)
        #expect(supporter.statusMsg == String(localized: "Couldn't connect"))
    }

    // MARK: the connector

    @Test func theConnectorShowsTheWarningInPlaceOfTheGrid() {
        for plan in [Plan.none, .supporter] {
            #expect(connectCanvasShowsWarning(
                connectionStatus: .connectFailed,
                displayReconnectTunnel: false,
                insufficientBalance: false,
                currentPlan: plan
            ))
        }
        for status in Self.otherStatuses {
            #expect(!connectCanvasShowsWarning(
                connectionStatus: status,
                displayReconnectTunnel: false,
                insufficientBalance: false,
                currentPlan: .none
            ), "\(String(describing: status)) hides the grid")
        }
        // the existing warnings are unchanged
        #expect(connectCanvasShowsWarning(connectionStatus: .connected, displayReconnectTunnel: true, insufficientBalance: false, currentPlan: .none))
        #expect(connectCanvasShowsWarning(connectionStatus: .connecting, displayReconnectTunnel: false, insufficientBalance: true, currentPlan: .none))
        #expect(!connectCanvasShowsWarning(connectionStatus: .connecting, displayReconnectTunnel: false, insufficientBalance: true, currentPlan: .supporter))
    }

    // MARK: the drawer

    @Test func aFailedConnectOffersRetryBesideDisconnect() {
        // the session is still standing, so disconnect stays, and retry
        // connects to the selected location again
        #expect(connectActionButtons(gateActive: false, connectionStatus: .connectFailed, displayReconnectTunnel: false)
            == ConnectActionButtons(disconnect: true, retry: true))
    }

    @Test func retryIsHiddenOutOfBalanceAndWithATunnelToReconnect() {
        // out of balance a retry cannot succeed: upgrade and disconnect only
        for displayReconnectTunnel in [false, true] {
            #expect(connectActionButtons(gateActive: true, connectionStatus: .connectFailed, displayReconnectTunnel: displayReconnectTunnel)
                == ConnectActionButtons(upgrade: true, disconnect: true))
        }
        // a tunnel to reconnect comes first: retrying the providers cannot help it
        #expect(connectActionButtons(gateActive: false, connectionStatus: .connectFailed, displayReconnectTunnel: true)
            == ConnectActionButtons(reconnect: true))
    }

    @Test func onlyAFailedConnectOffersRetry() {
        for status in Self.otherStatuses {
            for gateActive in [false, true] {
                for displayReconnectTunnel in [false, true] {
                    let buttons = connectActionButtons(
                        gateActive: gateActive,
                        connectionStatus: status,
                        displayReconnectTunnel: displayReconnectTunnel
                    )
                    #expect(!buttons.retry, "\(String(describing: status)) gate=\(gateActive) reconnect=\(displayReconnectTunnel)")
                }
            }
        }
    }

    /// Retry runs the drawer's connect. A failed connect is one the user
    /// already asked for, so the retry is not a start: it proceeds at once,
    /// without a balance fetch, and is never sent to upgrade.
    @Test func retryIsNotAStart() {
        #expect(connectAttempt(connectionStatus: .connectFailed) == .alreadyConnected)
    }

    /// The drawer renders the rule: Retry runs the drawer's connect, beside
    /// Disconnect. The view needs the app's environment, so this reads its
    /// source.
    @Test func theDrawerShowsRetryBesideDisconnect() throws {
        let actions = try Self.source("network/Main/Connect/ConnectActions/ConnectActions.swift")
        let start = try #require(actions.range(of: "if actionButtons.retry {"), "no retry row")
        let end = try #require(actions.range(of: "} else if actionButtons.disconnect {", range: start.upperBound..<actions.endIndex))
        let row = actions[start.upperBound..<end.lowerBound]
        #expect(row.contains("text: \"Retry\""))
        #expect(row.contains("action: connect,"))
        #expect(row.contains("text: \"Disconnect\""))
        #expect(row.contains("action: disconnect,"))
    }

    // MARK: the string

    @Test func couldNotConnectIsTranslatedInEveryLocale() throws {
        let data = try Data(contentsOf: Self.appRoot.appendingPathComponent("network/Shared/Resources/Localizable.xcstrings"))
        let catalog = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let strings = try #require(catalog?["strings"] as? [String: Any])
        // every locale the catalog ships a translation for
        var locales = Set<String>()
        for case let entry as [String: Any] in strings.values {
            if let localizations = entry["localizations"] as? [String: Any] {
                locales.formUnion(localizations.keys)
            }
        }
        #expect(locales.contains("zh-Hans"))

        let entry = try #require(strings["Couldn't connect"] as? [String: Any], "the catalog has no Couldn't connect")
        #expect(entry["extractionState"] as? String != "stale")
        let localizations = try #require(entry["localizations"] as? [String: Any])

        var missing: [String] = []
        for locale in locales.sorted() {
            let unit = (localizations[locale] as? [String: Any])?["stringUnit"] as? [String: Any]
            guard let value = unit?["value"] as? String, !value.isEmpty else {
                missing.append(locale)
                continue
            }
            if locale == "en" {
                #expect(value == "Couldn't connect")
            } else {
                #expect(value != "Couldn't connect", "\(locale) is English")
            }
        }
        #expect(missing.isEmpty, "not translated: \(missing)")
    }
}
