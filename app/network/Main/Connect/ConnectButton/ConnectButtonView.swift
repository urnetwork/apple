//
//  ConnectButtonView.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2024/12/27.
//

import SwiftUI
import URnetworkSdk

struct ConnectButtonView: View {
    
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var deviceManager: DeviceManager
    
    let gridPoints: [SdkId: SdkProviderGridPoint]
    let gridWidth: Int32
    let connectionStatus: ConnectionStatus?
    let windowCurrentSize: Int32
    let connect: () -> Void
    let disconnect: () -> Void
    let connectTunnel: () -> Void
    let contractStatus: SdkContractStatus?
    let openUpgradeSheet: () -> Void
    let currentPlan: Plan
    let isPollingSubscriptionBalance: Bool
    
    @Binding var tunnelConnected: Bool
    
    let canvasWidth: CGFloat = 256
    
    @State var displayReconnectTunnel: Bool = false
    
    @StateObject private var viewModel: ViewModel = ViewModel()
    
    var body: some View {
        
        VStack {
        
            ZStack {
                
                if (isPollingSubscriptionBalance) {
                    
                    ConnectProcessingSubscriptionView()
                    
                } else if (displayReconnectTunnel || (contractStatus?.insufficientBalance == true && currentPlan == .none)) {
                    
                    ConnectErrorStateView()
                    
                } else {
                 
                    /**
                     * Disconnected
                     */
                    ConnectCanvasDisconnectedStateView()
                        .opacity(connectionStatus == .disconnected ? 1 : 0)
                        .animation(.easeInOut(duration: 0.5), value: connectionStatus)
                    
                    /**
                     * Connecting grid
                     */
                    ConnectCanvasConnectingStateView(gridPoints: gridPoints, gridWidth: gridWidth)
                        .opacity((connectionStatus == .connecting || connectionStatus == .destinationSet)
                            ? 1
                            : 0)
                        .animation(.easeInOut(duration: 0.5), value: connectionStatus)
                    
                    /**
                     * Connected
                     */
                    ConnectCanvasConnectedStateView(
                        canvasWidth: canvasWidth,
                        isActive: connectionStatus == .connected
                        // displayReconnectTunnel: displayReconnectTunnel
                    )
                    
                }
            
                // for capturing tap when disconnected
                Circle()
                    .fill(.clear)
                    .frame(width: canvasWidth, height: canvasWidth)
                    .contentShape(Circle())
                    .onTapGesture {
                        
                        if (connectionStatus == .disconnected &&
                            (contractStatus?.insufficientBalance != true || currentPlan == .supporter) &&
                            !isPollingSubscriptionBalance
                        ) {
                            connect()
                            
#if canImport(UIKit)
                            let impact = UIImpactFeedbackGenerator(style: .soft)
                            impact.impactOccurred()
#endif
                            
                        }
                        
                    }
                
            }
            .background(themeManager.currentTheme.tintedBackgroundBase)
            .mask {
                Image("ur.symbols.globe")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }

            
            Spacer().frame(height: 32)
            
            ConnectStatusIndicator(
                connectionStatus: connectionStatus,
                displayReconnectTunnel: displayReconnectTunnel,
                contractStatus: contractStatus,
                windowCurrentSize: windowCurrentSize,
                isPollingSubscriptionBalance: isPollingSubscriptionBalance,
                currentPlan: currentPlan
            )
            
            Spacer().frame(height: 16)
            
        }
        .padding()
        .onChange(of: connectionStatus) { _ in
            checkTunnelStatus()
        }
        .onChange(of: tunnelConnected) { _ in
            checkTunnelStatus()
        }
        
    }
    
    private func checkTunnelStatus() {
        
        if connectionStatus == .connected && !tunnelConnected {
            self.displayReconnectTunnel = true
        } else {
            self.displayReconnectTunnel = false
        }
        
    }
    
}

#Preview {
    ConnectButtonView(
        gridPoints: [:],
        gridWidth: 16,
        connectionStatus: .disconnected,
        windowCurrentSize: 12,
        connect: {},
        disconnect: {},
        connectTunnel: {},
        contractStatus: .none,
        openUpgradeSheet: {},
        currentPlan: .supporter,
        isPollingSubscriptionBalance: false,
        tunnelConnected: .constant(true)
    )
}
