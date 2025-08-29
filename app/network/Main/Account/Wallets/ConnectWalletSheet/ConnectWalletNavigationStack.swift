//
//  ConnectWalletNavigationStack.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2025/01/09.
//

import SwiftUI
import URnetworkSdk

struct ConnectWalletNavigationStack: View {
    
    @StateObject var viewModel: ViewModel = ViewModel()
    
    @EnvironmentObject var themeManager: ThemeManager
    
    var api: UrApiServiceProtocol
    @Binding var presentConnectWalletSheet: Bool
    
    var body: some View {
        NavigationStack(
            path: $viewModel.connectWalletNavigationPath
        ) {
        
            ConnectWalletSheetView(
                navigate: viewModel.navigate
            )
            
                .navigationDestination(for: ConnectWalletNavigationPath.self) { path in
                    switch path {
                        
                    case .external:
                        EnterWalletAddressView(
                            onSuccess: {
                                presentConnectWalletSheet = false
                            },
                            api: api
                        )

                    }
                }
            
        }
        .background(themeManager.currentTheme.tintedBackgroundBase)
    }
}

