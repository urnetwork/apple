//
//  ProfileView.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2024/12/10.
//

import SwiftUI
import URnetworkSdk

struct ProfileView: View {
    
    @StateObject private var viewModel: ViewModel
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var deviceManager: DeviceManager
    @EnvironmentObject var snackbarManager: UrSnackbarManager
    
    var back: () -> Void
    var networkName: String?
    var userAuth: String?
    /// True when the account has no verified identity method (email/Google/Apple)
    /// bound yet, so it's still on its auto-generated name and needs the
    /// claim-name flow (no reclaim cooldown on the old name) rather than
    /// change-name (which applies a 24h cooldown to protect the old name).
    var needsNameClaim: Bool

    init(api: SdkApi, back: @escaping () -> Void, networkName: String?, userAuth: String?, needsNameClaim: Bool = false) {
        _viewModel = StateObject.init(wrappedValue: ViewModel(
            api: api
        ))
        self.back = back
        self.userAuth = userAuth
        self.networkName = networkName
        self.needsNameClaim = needsNameClaim
    }
    
    var body: some View {
        
        VStack {
        
            HStack {
                UrLabel(text: "Network name")
                
                Spacer()
            }
            
            if viewModel.isEditingNetworkName {
                // Editable view
                HStack {
                    TextField("Enter network name", text: $viewModel.editedNetworkName)
                        .textFieldStyle(.plain)
                        .font(themeManager.currentTheme.bodyFont)
                        .foregroundColor(themeManager.currentTheme.textColor)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .autocapitalization(.none)
                        #endif
                }
                .padding()
                .background(themeManager.currentTheme.tintedBackgroundBase)
                .cornerRadius(8)
                
                if let error = viewModel.networkNameError {
                    Text(error)
                        .font(themeManager.currentTheme.secondaryBodyFont)
                        .foregroundColor(.red)
                }
                
                HStack(spacing: 12) {
                    UrButton(
                        text: "Save",
                        action: {
                            Task {
                                if needsNameClaim {
                                    let result = await viewModel.claimNetworkName()
                                    handleNetworkNameResult(result)
                                } else {
                                    let result = await viewModel.saveNetworkName()
                                    handleNetworkNameResult(result)
                                }
                            }
                        },
                        enabled: !viewModel.isSavingNetworkName && !viewModel.editedNetworkName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                        isProcessing: viewModel.isSavingNetworkName
                    )
                    
                    Button(action: {
                        viewModel.cancelEditingNetworkName()
                    }) {
                        Text("Cancel")
                    }
                }
            } else {
                // Read-only view
                HStack {
                    Text(networkName ?? "")
                        .font(themeManager.currentTheme.bodyFont)
                        .foregroundColor(themeManager.currentTheme.textColor)
                    
                    Spacer()
                    
                    Button(action: {
                        viewModel.startEditingNetworkName(currentName: networkName ?? "")
                    }) {
                        Image(systemName: "pencil")
                            .foregroundColor(themeManager.currentTheme.textMutedColor)
                    }
                }
                
                HStack {
                    if needsNameClaim {
                        Text("Claim a custom network name to replace your auto-generated one")
                            .font(themeManager.currentTheme.secondaryBodyFont)
                            .foregroundColor(themeManager.currentTheme.textMutedColor)
                    } else {
                        Text("Tap the edit icon to change your network name")
                            .font(themeManager.currentTheme.secondaryBodyFont)
                            .foregroundColor(themeManager.currentTheme.textMutedColor)
                    }
                    Spacer()
                }
            }
            
            Spacer().frame(height: 32)
            
            HStack {
             
                Button(action: {
                    
                    guard let userAuth = userAuth else { return }
                    
                    Task {
                        let result = await viewModel.sendPasswordResetLink(userAuth)
                        self.handlePasswordResetLinkResult(result)
                    }
                    
                }) {
                    Text("Update password")
                }
                .disabled(userAuth == nil || viewModel.isSendingPasswordResetLink)
                
                Spacer()
                
            }
            
            Spacer()
        }
        .padding()
        .frame(maxWidth: 600)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private func handlePasswordResetLinkResult(_ result: Result<Void, Error>) {
        switch result {
        case .success:
            if let userAuth = userAuth {
                snackbarManager.showSnackbar(message: String(localized: "Password reset link sent to \(userAuth)."))
            } else {
                snackbarManager.showSnackbar(message: String(localized: "Something went wrong finding your account"))
            }
        case .failure:
            snackbarManager.showSnackbar(message: String(localized: "Error sending password reset link"))
        }
    }
    
    private func handleNetworkNameResult(_ result: Result<String, Error>) {
        switch result {
        case .success(let newName):
            snackbarManager.showSnackbar(message: String(localized: "Network name changed to \(newName)"))
            // The displayed network name comes from the cached JWT
            // (deviceManager.parsedJwt?.networkName), which isn't reissued by
            // this call — force a refresh so the new name propagates to this
            // screen and anywhere else the JWT-derived name is shown.
            do {
                try deviceManager.device?.refreshToken(0)
            } catch {
                print("Error refreshing JWT after network name change: \(error)")
            }
        case .failure(let error):
            print("Error changing network name: \(error)")
            snackbarManager.showSnackbar(message: String(localized: "Error changing network name"))
        }
    }
}

#Preview {
    ProfileView(
        api: SdkApi(),
        back: {},
        networkName: "hello_world",
        userAuth: "hello@ur.io"
    )
}
