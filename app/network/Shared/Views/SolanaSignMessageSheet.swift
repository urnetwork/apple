//
//  SolanaSignMessageSheet.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2025/05/14.
//

import SwiftUI

struct SolanaSignMessageSheet: View {
    
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var connectWalletProviderViewModel: ConnectWalletProviderViewModel
    
    var isSigningMessage: Bool
    var setIsSigningMessage: (Bool) -> Void
    var signButtonText: LocalizedStringKey
    var signButtonLabelText: LocalizedStringKey
    var message: String
    
    var body: some View {
        VStack {
            
            if (connectWalletProviderViewModel.connectedPublicKey == nil) {
                
                HStack {
                    Text("Connect a wallet")
                        .font(themeManager.currentTheme.toolbarTitleFont)
                    Spacer()
                }
                .padding(.horizontal, 16)
                
                Spacer().frame(height: 16)
                
                /**
                 * Wallet disconnected
                 */
             
                HStack(spacing: 12) {
                    
                    Button(action: {
                        connectWalletProviderViewModel.connectPhantomWallet()
                    }) {
                        
                        VStack {
                            Image("phantom.white.logo")
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 36, height: 36)
                                .padding()
                                .background(Color(hex: "#ab9ff2"))
                                .cornerRadius(12)
                            

                            Text("Phantom")
                                .font(themeManager.currentTheme.secondaryBodyFont)
                                .foregroundColor(themeManager.currentTheme.textColor)
                        }
                        
                    }
                    
                    Button(action: {
                        connectWalletProviderViewModel.connectSolflareWallet()
                    }) {
                        
                        VStack {
                            Image("solflare.logo")
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 36, height: 36)
                                .padding()
                                .background(.urWhite)
                                .cornerRadius(12)
                            

                            Text("Solflare")
                                .font(themeManager.currentTheme.secondaryBodyFont)
                                .foregroundColor(themeManager.currentTheme.textColor)
                        }
                        
                    }
                    
                    
                }
                
            } else {
                
                HStack {
                    // Text("Sign in")
                    Text(signButtonLabelText)
                        .font(themeManager.currentTheme.toolbarTitleFont)
                    Spacer()
                }
                .padding(.horizontal, 16)
                
                Spacer().frame(height: 16)
                
                HStack {
                    /**
                     * Wallet connected
                     */
                    UrButton(
                        // text: "Sign in with Solana",
                        text: signButtonText,
                        action: {
                            
                            setIsSigningMessage(true)
                            
                            if  (connectWalletProviderViewModel.connectedWalletProvider == ConnectedWalletProvider.phantom) {
                                connectWalletProviderViewModel.signMessagePhantom(
                                    // message: connectWalletProviderViewModel.welcomeMessage
                                    message: message
                                )
                            }
    
                            if  (connectWalletProviderViewModel.connectedWalletProvider == ConnectedWalletProvider.solflare) {
                                connectWalletProviderViewModel.signMessageSolflare(
                                    // message: connectWalletProviderViewModel.welcomeMessage
                                    message: message
                                )
                            }
                        },
                        enabled: !isSigningMessage,
                        isProcessing: isSigningMessage
                    )
                    
                }
                .padding(.horizontal, 16)
                // .frame(maxWidth: .infinity)
                
            }
            
        }
    }
}

#Preview {
    SolanaSignMessageSheet(
        isSigningMessage: false,
        setIsSigningMessage: {_ in },
        signButtonText: "Sign in with Solana",
        signButtonLabelText: "Sign in",
        message: "Welcome to URnetwork"
    )
}
