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
    var dismiss: () -> Void
    var beginSigning: (() -> String?)? = nil
    /// The wallet would not open (or its request could not be made): the
    /// owner shows the failure's message, where a snackbar would sit behind
    /// the sheet.
    var onFailure: (SolanaWalletFailure) -> Void
    
    var body: some View {
        VStack {
            
            if (connectWalletProviderViewModel.connectedPublicKey == nil) {
                
                HStack {
                    Text("Connect a wallet")
                        .font(themeManager.currentTheme.toolbarTitleFont)
                    
                    Spacer()
                    
                    #if os(macOS)
                    Button(
                        action: dismiss
                    ) {
                        Image(systemName: "xmark")
                    }
                    #endif
                    
                }
                // .padding(.horizontal, 16)
                
                Spacer().frame(height: 16)
                
                /**
                 * Wallet disconnected
                 */
             
                HStack(spacing: 12) {
                     
                    Button(
                        action: {
                            connectWalletProviderViewModel.connectPhantomWallet(onOpenFailed: onFailure)
                        },
                    ) {
                        
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
                    .buttonStyle(.plain)
                    .disabled(!connectWalletProviderViewModel.isWalletAppInstalled(.phantom))
                        
                    
                    Button(action: {
                        connectWalletProviderViewModel.connectSolflareWallet(onOpenFailed: onFailure)
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
                    .buttonStyle(.plain)
                    .disabled(!connectWalletProviderViewModel.isWalletAppInstalled(.solflare))
                    
                
                }
                
                if (!connectWalletProviderViewModel.isWalletAppInstalled(.solflare) && !connectWalletProviderViewModel.isWalletAppInstalled(.phantom)) {
                    
                    Spacer().frame(height: 12)
                    
                    HStack {
                        Text("Please install Phantom or Solflare to use this feature")
                            .font(themeManager.currentTheme.bodyFont)
                        
                        Spacer()
                    }
                }
                
            } else {
                
                HStack {
                    // Text("Sign in")
                    Text(signButtonLabelText)
                        .font(themeManager.currentTheme.toolbarTitleFont)
                    Spacer()
                }
                // .padding(.horizontal, 16)
                
                Spacer().frame(height: 16)
                
                HStack {
                    /**
                     * Wallet connected
                     */
                    UrButton(
                        text: signButtonText,
                        action: {
                            
                            guard let provider = connectWalletProviderViewModel.connectedWalletProvider else {
                                return
                            }

                            let attemptId = beginSigning?()
                            if beginSigning != nil && attemptId == nil { return }
                            setIsSigningMessage(true)

                            let signFailed = { (failure: SolanaWalletFailure) in
                                setIsSigningMessage(false)
                                onFailure(failure)
                            }
                            let didStartSigning: Bool
                            switch provider {
                            case .phantom:
                                didStartSigning = connectWalletProviderViewModel.signMessagePhantom(
                                    message: message,
                                    attemptId: attemptId,
                                    onOpenFailed: signFailed
                                )
                            case .solflare:
                                didStartSigning = connectWalletProviderViewModel.signMessageSolflare(
                                    message: message,
                                    attemptId: attemptId,
                                    onOpenFailed: signFailed
                                )
                            case .bittensor:
                                // bittensor signs through the ur.io/wallet-connect
                                // bridge, not this solana sheet
                                setIsSigningMessage(false)
                                return
                            }

                            if !didStartSigning {
                                setIsSigningMessage(false)
                            }
                        },
                        enabled: !isSigningMessage,
                        isProcessing: isSigningMessage
                    )
                    
                }
                // .padding(.horizontal, 16)
                // .frame(maxWidth: .infinity)
                
            }
            
        }
        .padding()
    }
}

#Preview {
    SolanaSignMessageSheet(
        isSigningMessage: false,
        setIsSigningMessage: {_ in },
        signButtonText: "Sign in with Solana",
        signButtonLabelText: "Sign in",
        message: "Welcome to URnetwork",
        dismiss: {},
        onFailure: {_ in }
    )
    .environmentObject(ThemeManager.shared)
    .environmentObject(ConnectWalletProviderViewModel())
}
