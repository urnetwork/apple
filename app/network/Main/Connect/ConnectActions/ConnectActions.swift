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
    let currentPlan: Plan
    let isPollingSubscriptionBalance: Bool
    let availableByteCount: Int
    let pendingByteCount: Int
    let usedByteCount: Int
    let promptMoreDataFlow: () -> Void
    let meanReliabilityWeight: Double
    let totalReferrals: Int
    
    @EnvironmentObject var themeManager: ThemeManager
    
    var body: some View {
            
            VStack {
                
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.secondary.opacity(0.3))
                    .frame(width: 36, height: 4)
                    .padding(.top, 8)
                
                Spacer().frame(height: 16)
                
                VStack {
                    
                    /**
                     * Connect button
                     */
                    VStack {
                     
                        HStack {
                        
                            Button(action: {
                                setIsPresented(true)
                            }) {
                                
                                SelectedProvider(
                                    selectedProvider: selectedProvider,
                                    openSelectProvider: {setIsPresented(true)}
                                )
                                
                            }
                            
                            Spacer()
                        }
                        
                        // todo - handle insufficient balance
                        
                        //                if (contractStatus?.insufficientBalance == true && currentPlan != .supporter && !isPollingSubscriptionBalance) {
                        //
                        //                    UrButton(
                        //                        text: "Subscribe to fix",
                        //                        action: {
                        //                            openUpgradeSheet()
                        //                            // connectTunnel()
                        //                        },
                        //                        style: .outlineSecondary
                        //                    )
                        //
                        //                }
                        
                        
                        if (connectionStatus == .disconnected) {
                            HStack {
                                UrButton(text: "Connect", action: connect)
                            }
                        }
                        
                        if (connectionStatus != .disconnected && !displayReconnectTunnel) {
                            UrButton(text: "Disconnect", action: disconnect)
                        }
                        
                        if displayReconnectTunnel {
                            UrButton(
                                text: "Reconnect",
                                action: reconnectTunnel ?? {},
                            )
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
                    if (currentPlan != .supporter) {
                        
                        VStack {
                            
                            HStack {
                                Text("Data usage")
                                    .font(themeManager.currentTheme.toolbarTitleFont)
                                
                                Spacer()
                            }
                            
                            UsageBar(
                                availableByteCount: availableByteCount,
                                pendingByteCount: pendingByteCount,
                                usedByteCount: usedByteCount,
                                meanReliabilityWeight: meanReliabilityWeight,
                                totalReferrals: totalReferrals
                            )
                            
                            Spacer().frame(height: 24)
                            
                            UrButton(text: "Get more data", action: {
                                promptMoreDataFlow()
                            })
                            
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
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
    
}

//#Preview {
//    ConnectActions()
//}
