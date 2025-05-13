//
//  AuthSolanaWalletSheet.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2025/05/10.
//

import SwiftUI

struct AuthSolanaWalletSheet: View {
    
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var connectWalletProviderViewModel: ConnectWalletProviderViewModel
    
    // let verifyMessage = "Welcome to URnetwork"
    var isSigningMessage: Bool
    var setIsSigningMessage: (Bool) -> Void
    
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
                    Text("Sign in")
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
                        text: "Sign in with Solana",
                        action: {
                            
                            setIsSigningMessage(true)
                            
                            if  (connectWalletProviderViewModel.connectedWalletProvider == ConnectedWalletProvider.phantom) {
                                connectWalletProviderViewModel.signMessagePhantom(
                                    message: connectWalletProviderViewModel.welcomeMessage
                                )
                            }
    
                            if  (connectWalletProviderViewModel.connectedWalletProvider == ConnectedWalletProvider.solflare) {
                                connectWalletProviderViewModel.signMessageSolflare(
                                    message: connectWalletProviderViewModel.welcomeMessage
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
    AuthSolanaWalletSheet(
        isSigningMessage: false,
        setIsSigningMessage: {_ in }
    )
}
