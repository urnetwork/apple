//
//  OutOfBalanceDisconnectFirstTests.swift
//  networkTests
//
//  A held tunnel stops a checkout that has to go through it. Where that is the
//  build's checkout (the direct-download Mac: a page in a web view or the browser)
//  the out-of-balance alert says to disconnect first, beside the Disconnect it
//  names, and nothing disconnects for the user. Every input is passed in; the
//  sources are read for what only a view or the other build can show.
//

import Foundation
import Testing
@testable import URnetwork

struct OutOfBalanceDisconnectFirstTests {

    // …/apple/app/networkTests/OutOfBalanceDisconnectFirstTests.swift -> …/apple/app
    private static let appRoot = URL(fileURLWithPath: #filePath)
        .resolvingSymlinksInPath()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static func source(_ relativePath: String) throws -> String {
        try String(contentsOf: appRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// The text of a declaration: from `start` to the first line closing it at `indent`.
    private static func body(_ source: String, from start: String, closing: String) throws -> String {
        let from = try #require(source.range(of: start))
        let end = try #require(source.range(of: closing, range: from.upperBound..<source.endIndex))
        return String(source[from.lowerBound..<end.upperBound])
    }

    private static let requestedStatuses: [ConnectionStatus] = [.connecting, .destinationSet, .connected, .connectFailed]

    private func gated(_ status: ConnectionStatus?) -> ConnectActionButtons {
        connectActionButtons(gateActive: true, connectionStatus: status, displayReconnectTunnel: false)
    }

    // MARK: which builds

    @Test func onlyTheDirectDownloadsCheckoutRidesTheTunnel() {
        #expect(BillingDistribution.direct.checkoutRidesTunnel)
        // iOS: the App Store purchase runs in system daemons, outside the tunnel.
        // The Mac App Store: the purchase flow disconnects around the store itself.
        #expect(!BillingDistribution.appStore.checkoutRidesTunnel)
    }

    @Test func theBuildFlagPicksTheDistribution() {
        #if DIRECT_DOWNLOAD
        #expect(BillingDistribution.current == .direct)
        #expect(BillingDistribution.current.checkoutRidesTunnel)
        #else
        #expect(BillingDistribution.current == .appStore)
        #expect(!BillingDistribution.current.checkoutRidesTunnel)
        #endif
    }

    // MARK: when the alert says it

    @Test func theAlertSaysItWhileATunnelHoldsTheTraffic() {
        for status in Self.requestedStatuses {
            #expect(outOfBalanceNotice(buttons: gated(status), tunnelStarted: true, checkoutRidesTunnel: true).disconnectFirst, "\(status)")
        }
    }

    @Test func theAlertDoesNotSayItOnABuildWhoseCheckoutStaysOutOfTheTunnel() {
        for status in Self.requestedStatuses {
            #expect(!outOfBalanceNotice(buttons: gated(status), tunnelStarted: true, checkoutRidesTunnel: false).disconnectFirst, "\(status)")
        }
    }

    @Test func theAlertDoesNotSayItWithNothingInTheWay() {
        for status in Self.requestedStatuses {
            // no tunnel running: the page goes out the normal way
            #expect(!outOfBalanceNotice(buttons: gated(status), tunnelStarted: false, checkoutRidesTunnel: true).disconnectFirst, "\(status)")
        }
        // nothing requested: nothing to disconnect from
        for status in [ConnectionStatus.disconnected, nil] {
            #expect(!outOfBalanceNotice(buttons: gated(status), tunnelStarted: true, checkoutRidesTunnel: true).disconnectFirst)
        }
    }

    @Test func aDataLimitHasNothingToPayFor() {
        let paying = connectActionButtons(gateActive: false, connectionStatus: .connected, displayReconnectTunnel: false)
        #expect(!outOfBalanceNotice(buttons: paying, tunnelStarted: true, checkoutRidesTunnel: true).disconnectFirst)
    }

    @Test func theLineComesWithADisconnect() {
        for status in Self.requestedStatuses {
            let buttons = gated(status)
            #expect(outOfBalanceNotice(buttons: buttons, tunnelStarted: true, checkoutRidesTunnel: true).disconnectFirst)
            #expect(buttons.disconnect, "\(status)")
        }
    }

    // MARK: what the alert shows

    @Test func theAlertShowsTheLineBesideItsDisconnect() throws {
        let actions = try Self.source("network/Main/Connect/ConnectActions/ConnectActions.swift")
        #expect(actions.contains("checkoutRidesTunnel: BillingDistribution.current.checkoutRidesTunnel"))
        let section = try Self.body(
            actions,
            from: "private var actionButtonsSection: some View {",
            closing: "* sufficient balance"
        )
        let line = try #require(section.range(of: "if notice.disconnectFirst {"))
        let text = try #require(section.range(of: "Text(\"To upgrade, press Disconnect first, and turn off the kill switch if it's on. Payment can't get through until you do.\")"))
        let id = try #require(section.range(of: "\"acceptance.insufficientBalance.disconnectFirst\""))
        let disconnect = try #require(section.range(of: "accessibilityIdentifier: \"acceptance.disconnect\""))
        #expect(line.lowerBound < text.lowerBound)
        #expect(text.lowerBound < id.lowerBound)
        #expect(id.lowerBound < disconnect.lowerBound)
    }

    // The press only disconnects: the provide mode stands, and nothing reconnects by itself.
    @Test func theDisconnectLeavesTheProvideModeAlone() throws {
        let model = try Self.source("network/Shared/ViewModels/ConnectViewModel.swift")
        let disconnect = try Self.body(model, from: "    func disconnect() {", closing: "\n    }\n")
        #expect(disconnect.contains("runConnectCommand(.disconnect)"))
        #expect(!disconnect.contains("rovide"))
    }

    // MARK: what the builds rest on

    @Test func theDirectCheckoutIsAPageAndTheIosPurchaseStaysOutOfTheTunnel() throws {
        let store = try Self.source("network/Shared/Billing/StripeSubscriptionStore.swift")
        #expect(store.contains("StripeCheckoutView(request: checkout, store: self)"))
        #expect(store.contains("NSWorkspace.shared.open(url)"))
        let view = try Self.source("network/Shared/Billing/StripeCheckoutView.swift")
        #expect(view.contains("import WebKit"))
        // iOS leaves the App Store's daemons outside the tunnel only without this
        // setting (the A6 note on AppStoreSubscriptionManager.purchase)
        let vpn = try Self.source("network/Shared/ViewModels/VPNManager.swift")
        #expect(!vpn.contains("includeAllNetworks"))
    }
}
