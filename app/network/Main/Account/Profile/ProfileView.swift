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
    
    init(api: SdkApi, back: @escaping () -> Void, networkName: String?, userAuth: String?) {
        _viewModel = StateObject.init(wrappedValue: ViewModel(
            api: api
        ))
        self.back = back
        self.userAuth = userAuth
        self.networkName = networkName
    }
    
    var body: some View {
        
        VStack {
         
//            HStack {
//                Text("Profile")
//                    .font(themeManager.currentTheme.titleFont)
//                    .foregroundColor(themeManager.currentTheme.textColor)
//                
//                Spacer()
//            }
//            
//            Spacer().frame(height: 64)
            
            HStack {
                UrLabel(text: "Network name")
                
                Spacer()
            }
            
            HStack {
                Text(networkName ?? "")
                    .font(themeManager.currentTheme.bodyFont)
                    .foregroundColor(themeManager.currentTheme.textColor)
                
                Spacer()
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
                snackbarManager.showSnackbar(message: "Password reset link sent to \(userAuth)")
            } else {
                snackbarManager.showSnackbar(message: "Something went wrong finding your account")
            }
        case .failure:
            snackbarManager.showSnackbar(message: "Error sending password reset link")
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
