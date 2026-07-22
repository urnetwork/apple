//
//  ConnectActions.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 9/25/25.
//

import SwiftUI
import URnetworkSdk

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
        
                        } else {
                            /**
                             * sufficient balance
                             */
                         
                            /**
                             * Action buttons
                             */
                            if (connectionStatus == .disconnected) {
                                HStack {
                                    UrButton(text: "Connect", action: connect)
                                }
                            }
                            
                            if (connectionStatus != .disconnected && !displayReconnectTunnel) {
                                UrButton(
                                    text: "Disconnect",
                                    action: disconnect,
                                    style: .outlineSecondary
                                )
                            }
                            
                            if displayReconnectTunnel {
                                UrButton(
                                    text: "Reconnect",
                                    action: reconnectTunnel ?? {},
                                )
                            }

                            /**
                             * Network peers status line: a dot (green when peers are
                             * online, amber at zero) + "{n} peers", always shown. Tapping
                             * opens the location chooser, which lists these peers at top.
                             * The extra top spacing pushes it just below the collapsed
                             * drawer's peek fold, so it appears only when the drawer opens.
                             */
                            Spacer().frame(height: 24)
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(peerCount > 0 ? Color.urGreen : Color(hex: "F5C242"))
                                    .frame(width: 8, height: 8)
                                Text(peerCount == 1 ? "You have 1 other device online" : "You have \(peerCount) other devices online")
                                    .font(themeManager.currentTheme.secondaryBodyFont)
                                    .foregroundColor(themeManager.currentTheme.textMutedColor)
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
