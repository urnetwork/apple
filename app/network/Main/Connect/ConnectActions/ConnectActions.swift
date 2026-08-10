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

struct ConnectActions: View {
    
    let connect: () -> Void
    let disconnect: () -> Void
    let connectionStatus: ConnectionStatus?
    let selectedProvider: SdkConnectLocation?
    let setIsPresented: (Bool) -> Void
    let displayReconnectTunnel: Bool
    let reconnectTunnel: (() -> Void)?
    let contractStatus: SdkContractStatus?
    let windowCurrentSize: Int32
    let isPollingSubscriptionBalance: Bool
    let availableByteCount: Int
    let pendingByteCount: Int
    let usedByteCount: Int
    let promptMoreDataFlow: () -> Void
    let meanReliabilityWeight: Double
    let totalReferrals: Int
    // when set, the usage bar referral row shares the referral link
    let referralCode: String?
    let isPro: Bool
    @Binding var selectedWindowType: WindowType
    @Binding var fixedIpSize: Bool
    @Binding var allowDirect: Bool
    @Binding var postQuantumEncryption: Bool
    let dailyBalanceByteCount: Int
    let openStatsSheet: (ConnectStatsSheet) -> Void

    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var networkPeersStore: NetworkPeersStore
    @EnvironmentObject var deviceManager: DeviceManager

    // ALL connected devices (a device is online whether or not it provides);
    // the chooser's peers section stays provide-filtered (connectable only)
    private var peerCount: Int { networkPeersStore.connectedCount }
    private var peersAvailable: Bool { networkPeersStore.peersAvailable }

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

    var body: some View {
            
            VStack {
                
                Spacer().frame(height: 16)
                
                VStack {
                    
                    /**
                     * Connect button
                     */
                    VStack(alignment: .leading) {
                     
                        SelectedProvider(
                            selectedProvider: selectedProvider,
                            openSelectProvider: {setIsPresented(true)}
                        )
                    
                        if (contractStatus?.insufficientBalance == true && !isPro && !isPollingSubscriptionBalance) {
                            /**
                             * out of balance
                             * not a supporter
                             */
                            
                            UrButton(
                                text: "Insufficient balance",
                                action: {
                                    promptMoreDataFlow()
                                },
                                style: .outlineSecondary
                            )
                            .connectActionsFold()

                        } else {
                            /**
                             * sufficient balance
                             */
                         
                            /**
                             * Action buttons
                             */
                            if (connectionStatus == .disconnected) {
                                HStack {
                                    UrButton(
                                        text: "Connect",
                                        action: connect,
                                        accessibilityIdentifier: "acceptance.connect"
                                    )
                                }
                                .connectActionsFold()
                            }

                            if (connectionStatus != .disconnected && !displayReconnectTunnel) {
                                UrButton(
                                    text: "Disconnect",
                                    action: disconnect,
                                    style: .outlineSecondary,
                                    accessibilityIdentifier: "acceptance.disconnect"
                                )
                                .connectActionsFold()
                            }

                            if displayReconnectTunnel {
                                UrButton(
                                    text: "Reconnect",
                                    action: reconnectTunnel ?? {},
                                )
                                .connectActionsFold()
                            }

                            /**
                             * Network peers status line: a dot (green when peers are
                             * online, amber at zero) + "{n} peers", always shown. Tapping
                             * opens the location chooser, which lists these peers at top.
                             * The extra top spacing pushes it just below the collapsed
                             * drawer's peek fold, so it appears only when the drawer opens.
                             * Peer state lives in the network extension's device, which
                             * only runs while the tunnel is up: until then the count would
                             * be a stale zero presented as fact, so the line goes gray and
                             * says discovery is disabled instead.
                             */
                            Spacer().frame(height: 24)
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(peersAvailable
                                        ? (peerCount > 0 ? Color.urGreen : Color(hex: "F5C242"))
                                        : themeManager.currentTheme.textMutedColor)
                                    .frame(width: 8, height: 8)
                                if peersAvailable {
                                    Text(peerCount == 1 ? "You have 1 other device online" : "You have \(peerCount) other devices online")
                                        .font(themeManager.currentTheme.secondaryBodyFont)
                                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                                } else {
                                    Text("Peer discovery disabled until connected")
                                        .font(themeManager.currentTheme.secondaryBodyFont)
                                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { setIsPresented(true) }

                            Spacer().frame(height: 6)
                            Text(discoverableText)
                                .font(themeManager.currentTheme.secondaryBodyFont)
                                .foregroundColor(themeManager.currentTheme.textMutedColor)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.leading, 16)

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
                             */
                            Toggle(isOn: $fixedIpSize) {
                                Text("Fixed IP")
                                    .font(themeManager.currentTheme.bodyFont)
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
                        openSheet: openStatsSheet
                    )

                    Spacer().frame(height: 16)

                    /**
                     * Upgrade and participate flows
                     */
                        
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
                                    promptMoreDataFlow()
                                }) {
                                    Text("Get Pro")
                                        .font(themeManager.currentTheme.secondaryBodyFont)
                                }
                            }
                            
                        }
                            
                        UsageBar(
                            availableByteCount: availableByteCount,
                            pendingByteCount: pendingByteCount,
                            usedByteCount: usedByteCount,
                            meanReliabilityWeight: meanReliabilityWeight,
                            totalReferrals: totalReferrals,
                            dailyBalanceByteCount: dailyBalanceByteCount,
                            referralCode: referralCode
                        )
                        
                    }
                    .padding()
                    .background(
                        themeManager.currentTheme.tintedBackgroundBase,
                    )
                    .cornerRadius(12)
                    
                }
            }
            
            .padding(.horizontal)
            .padding(.bottom)
            // the space sits inside the flexible frames below and has no top
            // padding above it, so fold offsets measured in it are offsets
            // from the top of the ConnectActions content, immune to any
            // centering slack a host's frame could introduce
            .coordinateSpace(name: connectActionsFoldCoordinateSpace)
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                Rectangle()
                    .fill(themeManager.currentTheme.tintedBackgroundBase)
                    .colorMultiply(Color(white: 0.8))
            )
    }
    
}

//#Preview {
//    ConnectActions()
//}
