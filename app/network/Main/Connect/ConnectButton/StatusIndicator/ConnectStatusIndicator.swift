//
//  ConnectStatusIndicator.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 9/20/25.
//

import SwiftUI
import URnetworkSdk

struct ConnectStatusIndicator: View {
    
    let connectionStatus: ConnectionStatus?
    let displayReconnectTunnel: Bool
    let contractStatus: SdkContractStatus?
    let windowCurrentSize: Int32
    let isPollingSubscriptionBalance: Bool
    let currentPlan: Plan
    
    @EnvironmentObject var themeManager: ThemeManager
    
    var statusMsgIconColor: Color {
        
        if (contractStatus?.insufficientBalance == true && currentPlan == .none) {
            return .urCoral
        } else {
            switch connectionStatus {
                case .disconnected: return .urElectricBlue
                case .connecting: return .urYellow
                case .destinationSet: return .urYellow
                case .connected: return displayReconnectTunnel ? .urCoral : .urGreen
                case .none: return .urElectricBlue
            }
        }
    }
    
    var statusMsg: String {
        
        if (isPollingSubscriptionBalance) {
            return String(localized: "Processing subscription balance...")
        } else if (contractStatus?.insufficientBalance == true && currentPlan == .none) {
            return String(localized: "Insufficient balance")
        } else {
            switch connectionStatus {
            case .disconnected: return String(localized: "Ready to connect")
            case .connecting, .destinationSet: return String(localized: "Connecting to providers")
                case .connected: do {
                    if displayReconnectTunnel {
                        return String(localized: "VPN tunnel disconnected 😓")
                    } else {
                        return String(localized: "Connected to \(windowCurrentSize) providers")
                    }
                }
                case .none: return ""
            }
        }
        
    }
    
    var body: some View {
        HStack {
            
            if connectionStatus != nil {
                ZStack {
                    Image("GlobeMask")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 16, height: 16)
                }
                .background(statusMsgIconColor)
            }
            
            Spacer().frame(width: 8)
            
            Text(statusMsg)
                .font(themeManager.currentTheme.bodyFont)
                .foregroundColor(themeManager.currentTheme.textColor)
            
        }
    }
}

#Preview {
    ConnectStatusIndicator(
        connectionStatus: .connected,
        displayReconnectTunnel: false,
        contractStatus: .none,
        windowCurrentSize: 8,
        isPollingSubscriptionBalance: false,
        currentPlan: .none
    )
}
