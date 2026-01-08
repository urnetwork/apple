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
//    let currentPlan: Plan
    let isPollingSubscriptionBalance: Bool
    let availableByteCount: Int
    let pendingByteCount: Int
    let usedByteCount: Int
    let promptMoreDataFlow: () -> Void
    let meanReliabilityWeight: Double
    let totalReferrals: Int
    let isPro: Bool
    @Binding var selectedWindowType: WindowType
    @Binding var fixedIpSize: Bool
    
    @EnvironmentObject var themeManager: ThemeManager
    
    // for testing
//    @State var connectMode = "Auto"
//    @State private var selectedWindowType: WindowType = .auto
//    @State var fixedSize: Bool = false
    
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
                                action: {},
                                enabled: false
                            )
        
                        } else {
                            /**
                             * sufficient balance
                             */
                            
//                            /**
//                             * connect window options
//                             */
//                            Picker(
//                                "Connect Mode",
//                                selection: $connectMode
//                            ) {
////                                ForEach(ConnectMode.allCases, id: \.self) {
////                                    Text($0.rawValue.capitalized)
////                                }
//                                Text("Auto")
//                                Text("Web")
//                                Text("Streaming")
//                            }.pickerStyle(.segmented)
//                            
//                            Spacer().frame(height: 12)
                         
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
                            
//                            Text(
//                                "lorem ipsum some text about using fixed IP"
//                            )
//                            .font(themeManager.currentTheme.secondaryBodyFont)
//                            .foregroundStyle(themeManager.currentTheme.textMutedColor)
                            
                            
                        }
                        
                    }
                    .padding()
                    .background(
                        themeManager.currentTheme.tintedBackgroundBase,
                    )
                    .cornerRadius(12)
                    
                    Spacer().frame(height: 16)
                    
                    /**
                     * Upgrade and participate flows
                     */
                    if (!isPro) {
                        
                        VStack(alignment: .leading, spacing: 0) {
                            
                            Text("Plan")
                                .font(themeManager.currentTheme.secondaryBodyFont)
                                .foregroundColor(themeManager.currentTheme.textMutedColor)
                            
                            HStack(alignment: .firstTextBaseline) {
                                 
                                Text("Free")
                                    .font(themeManager.currentTheme.titleCondensedFont)
                                    .foregroundColor(themeManager.currentTheme.textColor)
                            
                                Spacer()
 
                                Button(action: {
                                    promptMoreDataFlow()
                                }) {
                                    Text("Get Pro")
                                        .font(themeManager.currentTheme.secondaryBodyFont)
                                }
                                
                            }
                                
                            UsageBar(
                                availableByteCount: availableByteCount,
                                pendingByteCount: pendingByteCount,
                                usedByteCount: usedByteCount,
                                meanReliabilityWeight: meanReliabilityWeight,
                                totalReferrals: totalReferrals
                            )
                            
                        }
                        .padding()
                        .background(
                            themeManager.currentTheme.tintedBackgroundBase,
                        )
                        .cornerRadius(12)
                        
                    }
                    
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
    
//    private func createPerformanceProfile(
//        windowType: WindowType,
//        isFixedSize: Bool
//    ) -> SdkPerformanceProfile? {
//        if windowType == .auto {
//            return nil
//        }
//        
//        let performanceProfile = SdkPerformanceProfile()
//        performanceProfile.windowType = windowType == .quality ? SdkWindowTypeQuality : SdkWindowTypeSpeed
//        
//        let windowSizeSettings = SdkWindowSizeSettings()
//        windowSizeSettings.windowSizeMin = isFixedSize ? 1 : 2
//        windowSizeSettings.windowSizeMax = isFixedSize ? 1 : 4
//        
//        performanceProfile.windowSize = windowSizeSettings
//        
//        return performanceProfile
//        
//    }
    
}

//#Preview {
//    ConnectActions()
//}
