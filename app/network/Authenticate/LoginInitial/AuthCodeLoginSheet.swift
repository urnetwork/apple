//
//  AuthCodeLoginSheet.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2/21/26.
//

import SwiftUI
import URnetworkSdk

struct AuthCodeLoginSheet: View {
    
    @EnvironmentObject var themeManager: ThemeManager
    
    @StateObject private var viewModel: ViewModel
    
    let onSuccess: (_ jwt: String) -> Void
    
    init(
        urApiService: UrApiServiceProtocol,
        onSuccess: @escaping (_ jwt: String) -> Void
    ) {
        _viewModel = StateObject(wrappedValue: ViewModel(urApiService: urApiService))
        self.onSuccess = onSuccess
    }
    
    var body: some View {
        VStack {
            
            HStack {
             
                Text("Auth code login")
                    .font(themeManager.currentTheme.secondaryTitleFont)
                
                Spacer()
                
            }
            
            Spacer().frame(height: 24)
            
            UrTextField(
                text: $viewModel.authCode,
                label: "Authentication code",
                placeholder: "Enter your one-time auth code",
                supportingText: viewModel.loginFailed ? "There was an error validating your auth code. Please try again or generate a new one" : "",
                isEnabled: !viewModel.isLoading,
                validationState: viewModel.loginFailed ? .invalid : .valid,
                submitLabel: .done,
                onSubmit: {
                    Task {
                        let result = await viewModel.authCodeLogin()
                        self.handleAuthCodeLoginResult(result)
                    }
                },
                isSecure: true
            )
            
            Spacer().frame(height: 24)
            
            UrButton(
                text: "Launch",
                action: {
                    Task {
                        let result = await viewModel.authCodeLogin()
                        handleAuthCodeLoginResult(result)
                    }
                },
                enabled: !viewModel.authCode.isEmpty,
                isProcessing: viewModel.isLoading
            )
            
        }
        .padding()
    }
    
    @MainActor
    func handleAuthCodeLoginResult(_ result: Result<SdkAuthCodeLoginResult, Error>) {
        switch result {
            
        case .success(let authCodeLoginResult):
            onSuccess(authCodeLoginResult.jwt)
        
        case .failure(let error):
            print("error logging in with auth code: \(error.localizedDescription)")
            
        }
    }
    
}

#Preview {
    AuthCodeLoginSheet(
        urApiService: MockUrApiService(),
        onSuccess: {_ in}
    )
}
