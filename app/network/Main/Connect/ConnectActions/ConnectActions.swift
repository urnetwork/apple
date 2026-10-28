//
//  ConnectActions.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 9/25/25.
//

import SwiftUI
import URnetworkSdk

/// Coordinate space anchored at the top of [ConnectActions], in which the fold
/// marker reports the bottom edge of the connect button. The iOS drawer sizes
/// its collapsed peek so this fold sits a standard 12pt above the tab bar
/// (Android parity). The space lives inside ConnectActions so hosts that never
/// read the preference (macOS) still resolve it.
let connectActionsFoldCoordinateSpace = "connectActionsFold"

/// The bottom edge (maxY) of whichever connect/disconnect/reconnect button is
/// showing, measured in [connectActionsFoldCoordinateSpace]. Only one button
/// variant exists at a time; reduce keeps the deepest edge if that ever
/// changes.
struct ConnectActionsFoldPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        if let next = nextValue() {
            value = max(value ?? next, next)
        }
    }
}

private extension View {
    /// Marks this view's bottom edge as the collapsed drawer's fold. A
    /// zero-size sibling marker would add a VStack spacing slot, so the
    /// measurement rides on the button's background instead.
    func connectActionsFold() -> some View {
        background(
            GeometryReader { geometry in
                Color.clear.preference(
                    key: ConnectActionsFoldPreferenceKey.self,
                    value: geometry.frame(in: .named(connectActionsFoldCoordinateSpace)).maxY
                )
            }
        )
    }
}

/// The parts of the connect drawer a host lays out (apple/DUO.md, "Design
/// direction agreed after this research").
enum ConnectActionsPart: Equatable {
    /// the whole drawer: the location row, the action buttons and their
    /// notices, devices online and the connect options, the statistics and
    /// the plan (the phone drawer, the Mac)
    case drawer
    /// the action buttons and their notices alone, under the canvas of the
    /// split connect screen
    case actionButtons
    /// the drawer without its action buttons, in one column: the statistics
    /// pane beside the canvas
    case statisticsPane
    /// the drawer without its action buttons or devices online (both under
    /// the canvas), the statistics in two columns before the connect
    /// options: the pane under the canvas
    case stackedPane
}

/// The coordinate space of the iOS connect screen, in which the location row
/// reports its frame for the location picker's popover to point at.
let connectScreenCoordinateSpace = "connectScreen"

/// The frame of the drawer's location row in [connectScreenCoordinateSpace].
struct ConnectLocationRowFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero {
            value = next
        }
    }
}

struct ConnectActions: View {
    
    let connect: () -> Void
    let disconnect: () -> Void
    let connectionStatus: ConnectionStatus?
    let selectedProvider: SdkConnectLocation?
    let selectedProviderCount: Int
    let setIsPresented: (Bool) -> Void
    let displayReconnectTunnel: Bool
    let reconnectTunnel: (() -> Void)?
    let contractStatus: SdkContractStatus?
    let windowCurrentSize: Int32
    let isPollingSubscriptionBalance: Bool
    let availableByteCount: Int
    let pendingByteCount: Int
    let usedByteCount: Int
    // insufficient balance: the participate flow (introduction) for more data
    let promptMoreDataFlow: () -> Void
    // Get Pro: the same upgrade sheet Account presents from its plan row
    let openUpgradeSheet: () -> Void
    let meanReliabilityWeight: Double
    // the usage bar's referral row
    let referralLine: ReferralBonusLine
    // the usage bar referral row opens the one Referrals screen
    let openReferrals: () -> Void
    // the usage bar's info button and the out-of-balance Why? open the
    // "About your data" sheet
    let openDataInfo: () -> Void
    // why the balance is out (reserved or used up) and the reserved amount
    // it names, from the last balance reading
    let outOfBalanceKind: OutOfBalanceKind
    let reservedByteCount: Int
    // a connect insufficient balance blocked, waiting to be retried by
    // itself; cancelBalanceRecovery is the refused start's Cancel
    let balanceRecovery: BalanceRecoveryState
    let cancelBalanceRecovery: () -> Void
    let isPro: Bool
    // the renewal the store is retrying, for the plan card's past-due notice
    // (see PaymentPastDue), and the notice's "Update payment method" link
    let paymentPastDue: PaymentPastDue?
    let updatePaymentMethodURL: () async -> URL
    @Binding var selectedWindowType: WindowType
    @Binding var fixedIpSize: Bool
    @Binding var allowDirect: Bool
    @Binding var postQuantumEncryption: Bool
    let dailyBalanceByteCount: Int
    let openStatsSheet: (ConnectStatsSheet) -> Void
    // which part of the drawer this host shows
    var part: ConnectActionsPart = .drawer

    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var deviceManager: DeviceManager

    // second line under the peers count: whether this device is itself
    // discoverable/connectable as a peer (providing to same-network peers).
    private var discoverableText: String {
        if deviceManager.providerDiscoverable {
            return deviceManager.deviceName.isEmpty
                ? "This device is discoverable"
                : "This device is discoverable as \(deviceManager.deviceName)"
        }
        return "Enable provide mode to make this device discoverable"
    }

    private var actionButtons: ConnectActionButtons {
        connectActionButtons(
            gateActive: insufficientBalanceGateActive(
                insufficientBalance: contractStatus?.insufficientBalance == true,
                plan: isPro ? .supporter : .none,
                isPollingSubscriptionBalance: isPollingSubscriptionBalance
            ),
            connectionStatus: connectionStatus,
            displayReconnectTunnel: displayReconnectTunnel
        )
    }

    private var notice: OutOfBalanceNotice {
        outOfBalanceNotice(buttons: actionButtons, kind: outOfBalanceKind, recovery: balanceRecovery)
    }

    /// "You'll be reconnected when data is available again.", with Cancel for
    /// a refused start, which has no Disconnect to stop it.
    private var willReconnectLine: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("You'll be reconnected when data is available again.")
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(themeManager.currentTheme.textMutedColor)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("acceptance.insufficientBalance.willReconnect")

            if notice.cancel {
                Button(action: cancelBalanceRecovery) {
                    Text("Cancel")
                        .font(themeManager.currentTheme.secondaryBodyFont)
                        .underline()
                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("acceptance.insufficientBalance.cancelReconnect")
            }
        }
    }

    var body: some View {
        if part == .actionButtons {
            VStack(alignment: .leading) {
                actionButtonsSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            drawerContent
        }
    }

    private var drawerContent: some View {
        
        VStack {
            
            Spacer().frame(height: 16)
            
            VStack {
                
                /**
                 * Connect button
                 */
                VStack(alignment: .leading) {
                 
                    SelectedProvider(
                        selectedProvider: selectedProvider,
                        providerCount: selectedProviderCount,
                        openSelectProvider: {setIsPresented(true)}
                    )
                    // the location picker's popover points at this row
                    .background(
                        GeometryReader { rowGeometry in
                            Color.clear.preference(
                                key: ConnectLocationRowFramePreferenceKey.self,
                                value: rowGeometry.frame(in: .named(connectScreenCoordinateSpace))
                            )
                        }
                    )

                    if part == .drawer {
                        actionButtonsSection
                    }

                    if !actionButtons.upgrade && part != .stackedPane {
                        /**
                         * The extra top spacing pushes devices online just
                         * below the collapsed drawer's peek fold, so it
                         * appears only when the drawer opens.
                         */
                        Spacer().frame(height: 24)
                        connectDetails(showsPeers: true)
                    }
                    
                }
                .padding()
                .background(
                    themeManager.currentTheme.tintedBackgroundBase,
                )
                .cornerRadius(12)

                Spacer().frame(height: 16)

                /**
                 * Statistics and dns sections
                 */
                ConnectStatsSections(
                    openSheet: openStatsSheet,
                    columns: part == .stackedPane ? 2 : 1
                )

                /**
                 * The stacked pane shows its statistics first, then the
                 * connect options, which the drawer puts by the buttons
                 */
                if part == .stackedPane && !actionButtons.upgrade {
                    Spacer().frame(height: 16)

                    VStack(alignment: .leading) {
                        connectDetails(showsPeers: false)
                    }
                    .padding()
                    .background(
                        themeManager.currentTheme.tintedBackgroundBase,
                    )
                    .cornerRadius(12)
                }

                Spacer().frame(height: 16)

                /**
                 * Upgrade and participate flows
                 */
                planCard
                
            }
        }
        
        .padding(.horizontal)
        .padding(.bottom)
        // the space sits inside the flexible frames below and has no top
        // padding above it, so fold offsets measured in it are offsets
        // from the top of the ConnectActions content, immune to any
        // centering slack a host's frame could introduce
        .coordinateSpace(name: connectActionsFoldCoordinateSpace)
        // the stacked pane's two columns of statistics take its width
        .frame(maxWidth: part == .stackedPane ? .infinity : TabletLayout.contentWidth)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            Rectangle()
                .fill(themeManager.currentTheme.tintedBackgroundBase)
                .colorMultiply(Color(white: 0.8))
        )
    }

    /**
     * The action buttons and the notices that go with them. The drawer shows
     * them under the location row, above the collapsed peek's fold; the split
     * connect screen, under the canvas.
     */
    @ViewBuilder
    private var actionButtonsSection: some View {
        if actionButtons.upgrade {
            /**
             * out of balance
             * not a supporter
             * disconnect stays offered while a connect is
             * requested, so the tunnel can always be released.
             * The notice and both buttons sit above the fold
             * marker, so the collapsed drawer shows them. The
             * notice leads with when the free data refreshes,
             * so upgrading does not read as the only way back.
             */

            if notice.refresh {
                HStack(alignment: .firstTextBaseline) {
                    FreeRefreshCountdownText()

                    Button(action: openDataInfo) {
                        Text("Why?")
                            .font(themeManager.currentTheme.secondaryBodyFont)
                            .underline()
                            .foregroundColor(themeManager.currentTheme.textMutedColor)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("acceptance.insufficientBalance.why")
                }
            }

            // reserved data comes back as connections close
            // (no time promised); used up waits for the
            // refresh or an upgrade
            OutOfBalanceKindText(kind: notice.kind, reservedByteCount: reservedByteCount)
                .accessibilityIdentifier("acceptance.insufficientBalance.kind")

            if notice.held {
                Text(InsufficientBalanceNotice.body)
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(themeManager.currentTheme.textMutedColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("acceptance.insufficientBalance.notice")
            }

            if notice.willReconnect {
                willReconnectLine
            }
            
            HStack {
                UrButton(
                    text: "Insufficient balance",
                    action: {
                        promptMoreDataFlow()
                    },
                    style: .outlineSecondary,
                    accessibilityIdentifier: "acceptance.insufficientBalance.upgrade"
                )

                if actionButtons.disconnect {
                    UrButton(
                        text: "Disconnect",
                        action: disconnect,
                        style: .outlineSecondary,
                        accessibilityIdentifier: "acceptance.disconnect"
                    )
                }
            }
            .connectActionsFold()

        } else {
            /**
             * sufficient balance
             */
         
            /**
             * A start the gate refused waits on the balance
             * (the gate itself only shows while connected),
             * above the fold so the collapsed drawer shows it
             */
            if notice.willReconnect {
                willReconnectLine
            }

            /**
             * Action buttons
             */
            if actionButtons.connect {
                HStack {
                    UrButton(
                        text: "Connect",
                        action: connect,
                        accessibilityIdentifier: "acceptance.connect"
                    )
                }
                .connectActionsFold()
            }

            if actionButtons.retry {
                /**
                 * the connect failed: retry connects to the
                 * selected location again (the sdk rebuilds
                 * it), and disconnect stays the way out
                 */
                HStack {
                    UrButton(
                        text: "Retry",
                        action: connect,
                        accessibilityIdentifier: "acceptance.connect.retry"
                    )

                    UrButton(
                        text: "Disconnect",
                        action: disconnect,
                        style: .outlineSecondary,
                        accessibilityIdentifier: "acceptance.disconnect"
                    )
                }
                .connectActionsFold()
            } else if actionButtons.disconnect {
                UrButton(
                    text: "Disconnect",
                    action: disconnect,
                    style: .outlineSecondary,
                    accessibilityIdentifier: "acceptance.disconnect"
                )
                .connectActionsFold()
            }

            if actionButtons.reconnect {
                UrButton(
                    text: "Reconnect",
                    action: reconnectTunnel ?? {},
                )
                .connectActionsFold()
            }
        }
    }

    /**
     * Devices online, whether this device is discoverable, and the connect
     * options. The stacked split connect screen shows devices online under
     * the canvas instead.
     */
    @ViewBuilder
    private func connectDetails(showsPeers: Bool) -> some View {
        if showsPeers {
            ConnectPeersLine(openLocations: { setIsPresented(true) })

            Spacer().frame(height: 6)
        }
        Text(discoverableText)
            .font(themeManager.currentTheme.secondaryBodyFont)
            .foregroundColor(themeManager.currentTheme.textMutedColor)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, showsPeers ? 16 : 0)

        Spacer().frame(height: 24)

        Text("Connect options")
            .font(themeManager.currentTheme.secondaryBodyFont)
            .foregroundColor(themeManager.currentTheme.textMutedColor)
        
        /**
         * connect window options
         */
        Picker(
            "Connection Mode",
            selection: $selectedWindowType
        ) {
            ForEach(WindowType.allCases) { type in
                Text(type.displayName).tag(type)
            }
        }
        .pickerStyle(.segmented)

        Spacer().frame(height: 12)
        
        /**
         * fixed IP
         * a Fixed IP window keeps its one exit for the session
         * (connect stickyExit): no hourly rotation, no spare
         */
        Toggle(isOn: $fixedIpSize) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Fixed IP")
                    .font(themeManager.currentTheme.bodyFont)
                Text("Keeps one exit for the session; changes only if that provider goes offline.")
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(themeManager.currentTheme.textMutedColor)
            }
        }
        .disabled(selectedWindowType == .auto)
        
        Spacer().frame(height: 12)
        
        /**
         * Allow direct
         * When "Strong Anonymization" is true, "allowDirect" is false and vice versa
         */
        Toggle(isOn: Binding(
            get: { !allowDirect },
            set: { allowDirect = !$0 }
        )) {
            Text("Strong Anonymization")
                .font(themeManager.currentTheme.bodyFont)
        }

        Spacer().frame(height: 12)

        /**
         * Post quantum encryption
         * Opportunistic e2e: providers without support fall
         * back to plaintext at this layer
         */
        Toggle(isOn: $postQuantumEncryption) {
            Text("Post Quantum Encryption")
                .font(themeManager.currentTheme.bodyFont)
        }
    }

    private var planCard: some View {
            
        VStack(alignment: .leading, spacing: 0) {
            
            Text("Plan")
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(themeManager.currentTheme.textMutedColor)
            
            HStack(alignment: .firstTextBaseline) {
                 
                Text(isPro ? "Pro" : "Free")
                    .font(themeManager.currentTheme.titleCondensedFont)
                    .foregroundColor(themeManager.currentTheme.textColor)
            
                Spacer()

                if (!isPro) {
                    Button(action: {
                        openUpgradeSheet()
                    }) {
                        Text("Get Pro")
                            .font(themeManager.currentTheme.secondaryBodyFont)
                    }
                }
                
            }
                
            // a renewal whose payment did not go through, while
            // the store retries it, as on the account plan card
            if paymentPastDue != nil {
                PaymentPastDueNotice(updatePaymentMethodURL: updatePaymentMethodURL)
            }

            UsageBar(
                availableByteCount: availableByteCount,
                pendingByteCount: pendingByteCount,
                usedByteCount: usedByteCount,
                meanReliabilityWeight: meanReliabilityWeight,
                referralLine: referralLine,
                dailyBalanceByteCount: dailyBalanceByteCount,
                openReferrals: openReferrals,
                openDataInfo: openDataInfo
            )
            
        }
        .padding()
        .background(
            themeManager.currentTheme.tintedBackgroundBase,
        )
        .cornerRadius(12)
    }
    
}

/**
 * Network peers status line: a dot (green when peers are online, amber at
 * zero) + "{n} peers", always shown. Tapping opens the location chooser,
 * which lists these peers at top. Peer state lives in the network
 * extension's device, which only runs while the tunnel is up: until then the
 * count would be a stale zero presented as fact, so the line goes gray and
 * says discovery is disabled instead. The drawer shows it under the action
 * buttons; the stacked split connect screen, centered under the canvas.
 */
struct ConnectPeersLine: View {

    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var networkPeersStore: NetworkPeersStore

    let openLocations: () -> Void
    // the drawer's line spans its card; under the canvas it is centered
    var fillsWidth: Bool = true

    // ALL connected devices (a device is online whether or not it provides);
    // the chooser's peers section stays provide-filtered (connectable only)
    private var peerCount: Int { networkPeersStore.connectedCount }
    private var peersAvailable: Bool { networkPeersStore.peersAvailable }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(peersAvailable
                    ? (peerCount > 0 ? Color.urGreen : Color(hex: "F5C242"))
                    : themeManager.currentTheme.textMutedColor)
                .frame(width: 8, height: 8)
            if peersAvailable {
                // the catalog selects the plural form for the count
                Text("You have \(peerCount) other devices online")
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(themeManager.currentTheme.textMutedColor)
            } else {
                Text("Peer discovery disabled until connected")
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(themeManager.currentTheme.textMutedColor)
            }
            if fillsWidth {
                Spacer()
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { openLocations() }
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("acceptance.peers.open")
    }
}

//#Preview {
//    ConnectActions()
//}
