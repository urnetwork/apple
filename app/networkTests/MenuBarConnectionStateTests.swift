//
//  MenuBarConnectionStateTests.swift
//  networkTests
//
//  The macOS menu bar's connection row and icon read as connected only when
//  the sdk reports CONNECTED. They read every status but DISCONNECTED as
//  connected: the sdk's CONNECT_FAILED, which can last indefinitely, a
//  connect in progress and a start waiting on its balance all showed
//  "✓ Connected" and the connected icon.
//

#if os(macOS)
import Foundation
import Testing
import URnetworkSdk
@testable import URnetwork

@MainActor
struct MenuBarConnectionStateTests {

    private static let notConnectedStatuses: [ConnectionStatus?] = [
        .disconnected, .connecting, .destinationSet, .connectFailed, nil,
    ]

    @Test func onlyTheConnectedStatusReadsAsConnected() {
        let connected = MenuBarConnectionState(.connected)
        #expect(connected == .connected)
        #expect(connected.symbol == "checkmark")
        #expect(connected.label == String(localized: "Connected"))
        for status in Self.notConnectedStatuses {
            let state = MenuBarConnectionState(status)
            #expect(state != .connected, "\(String(describing: status)) reads as connected")
            #expect(state.symbol != "checkmark", "\(String(describing: status)) is checked")
        }
    }

    @Test func aConnectInProgressSaysConnecting() {
        for status in [ConnectionStatus.connecting, .destinationSet] {
            let state = MenuBarConnectionState(status)
            #expect(state == .connecting)
            #expect(state.symbol == "ellipsis")
            #expect(state.label == String(localized: "Connecting…"))
        }
    }

    @Test func aFailedConnectSaysWhatTheMainWindowSays() {
        let state = MenuBarConnectionState(.connectFailed)
        #expect(state == .failed)
        #expect(state.symbol == "exclamationmark.triangle")
        #expect(state.label == String(localized: "Couldn't connect"))
        let mainWindow = ConnectStatusIndicator(
            connectionStatus: .connectFailed,
            displayReconnectTunnel: false,
            contractStatus: nil,
            windowCurrentSize: 0,
            isPollingSubscriptionBalance: false,
            currentPlan: .none
        )
        #expect(state.label == mainWindow.statusMsg)
    }

    @Test func disconnectedAndNoStatusAreNotConnected() {
        for status: ConnectionStatus? in [.disconnected, nil] {
            let state = MenuBarConnectionState(status)
            #expect(state == .disconnected)
            #expect(state.symbol == "xmark")
            #expect(state.label == String(localized: "Connected"))
        }
    }

    @Test func theIconShowsConnectedOnlyWhenConnected() {
        let cases: [(status: ConnectionStatus?, providing: Bool, icon: String)] = [
            (status: .connected, providing: true, icon: "MenuBarProvideConnect"),
            (status: .connected, providing: false, icon: "MenuBarNoProvideConnect"),
            (status: .connectFailed, providing: true, icon: "MenuBarProvideNoConnect"),
            (status: .connectFailed, providing: false, icon: "MenuBarNoProvideNoConnect"),
            (status: .destinationSet, providing: true, icon: "MenuBarProvideNoConnect"),
            (status: .destinationSet, providing: false, icon: "MenuBarNoProvideNoConnect"),
            (status: .connecting, providing: true, icon: "MenuBarProvideNoConnect"),
            (status: .connecting, providing: false, icon: "MenuBarNoProvideNoConnect"),
            (status: .disconnected, providing: true, icon: "MenuBarProvideNoConnect"),
            (status: .disconnected, providing: false, icon: "MenuBarNoProvideNoConnect"),
            (status: nil, providing: true, icon: "MenuBarProvideNoConnect"),
            (status: nil, providing: false, icon: "MenuBarNoProvideNoConnect"),
        ]
        for c in cases {
            let icon = MenuBarConnectionState(c.status).iconName(providing: c.providing)
            #expect(icon == c.icon, "\(String(describing: c.status)), providing \(c.providing)")
        }
    }

    /// Connected with the tunnel stopped says what the main window says
    /// there, and the icon shows not connected. A connection from the
    /// location alone, while the window is hidden, is not checked: the
    /// tunnel listener is closed then.
    @Test func aStoppedTunnelSaysWhatTheMainWindowSays() {
        let state = MenuBarConnectionState(.connected, tunnelConnected: false)
        #expect(state == .tunnelDisconnected)
        #expect(state.symbol == "exclamationmark.triangle")
        let mainWindow = ConnectStatusIndicator(
            connectionStatus: .connected,
            displayReconnectTunnel: true,
            contractStatus: nil,
            windowCurrentSize: 0,
            isPollingSubscriptionBalance: false,
            currentPlan: .none
        )
        #expect(state.label == mainWindow.statusMsg)
        #expect(state.iconName(providing: false) == "MenuBarNoProvideNoConnect")
        #expect(MenuBarConnectionState(.destinationSet, fromLocation: true, tunnelConnected: false) == .connected)
        #expect(MenuBarConnectionState(.connected, tunnelConnected: true) == .connected)
    }

    /// Connect when disconnected, Disconnect for any connection asked for,
    /// and nothing with no status, where Disconnect had nothing to end.
    @Test func theActionNeedsAStatus() {
        #expect(MenuBarConnectAction(nil) == nil)
        #expect(MenuBarConnectAction(.disconnected) == .connect)
        for status in [ConnectionStatus.connecting, .destinationSet, .connected, .connectFailed] {
            #expect(MenuBarConnectAction(status) == .disconnect, "\(status)")
        }
    }
}
#endif
