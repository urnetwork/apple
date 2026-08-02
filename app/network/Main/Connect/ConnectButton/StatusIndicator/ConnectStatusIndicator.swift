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
                        // real plural rules live in Localizable.xcstrings
                        // ("Connected to %d providers")
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
            
            if connectionStatus == .connecting || connectionStatus == .destinationSet {
                AnimatedEllipsis()
            }
        }
    }
}

struct AnimatedEllipsis: View {
    @Environment(\.presentationActive) private var presentationActive
    @State private var dotCount = 0
    @State private var timer: Timer?

    var body: some View {
        ZStack(alignment: .leading) {
            Text("...")
                .opacity(0)
            Text(String(repeating: ".", count: dotCount))
        }
        .frame(width: 20, alignment: .leading)
        .onAppear {
            startTimer()
        }
        .onChange(of: presentationActive) { active in
            if active {
                startTimer()
            } else {
                stopTimer()
            }
        }
        .onDisappear {
            stopTimer()
        }
    }

    private func startTimer() {
        stopTimer()
        guard PresentationWorkState.shouldRun(
            presentationActive: presentationActive
        ) else {
            return
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
            dotCount = (dotCount + 1) % 4
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
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
