//
//  AuthCodeCreate.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 8/20/25.
//

import SwiftUI
import URnetworkSdk

struct AuthCodeCreate: View {
    
    @StateObject private var viewModel: ViewModel
    @EnvironmentObject var themeManager: ThemeManager
    
    let copyToPasteboard: (_ value: String) -> Void
    
    init(
        api: UrApiServiceProtocol,
        copyToPasteboard: @escaping (_ value: String) -> Void
    ) {
        self._viewModel = .init(wrappedValue: .init(urApiService: api))
        self.copyToPasteboard = copyToPasteboard
    }
    
    var body: some View {
        
        Button(
            action: {
                Task {
                    try await viewModel.createAuthCode()
                    if viewModel.authCode != nil {
                        viewModel.isPresented = true
                    }
                }
            }
        ) {
            
            Text("Create")
        }
        .disabled(viewModel.isLoading)
        .confirmationDialog(
            "Auth Code Create",
            isPresented: $viewModel.isPresented,
            presenting: viewModel.authCode
        ) { authCode in
            Button("Copy Auth Code") {
                copyToPasteboard(authCode)
            }
            
            Button("Close", role: .cancel) {
                viewModel.isPresented = false
            }
        } message: { authCode in
            
            Text(
                """
                Auth Code \n
                \(authCode.prefix(6))...\(authCode.suffix(6))
                """
            )
            
        }
        
    }
}

#Preview {
    AuthCodeCreate(
        api: MockUrApiService(),
        copyToPasteboard: {_ in}
    )
}
