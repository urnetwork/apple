//
//  AuthCodeCreateViewModel.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 8/20/25.
//

import SwiftUI

extension AuthCodeCreate {
    
    @MainActor
    class ViewModel: ObservableObject {
        
        @Published var isPresented: Bool = false
        @Published var isLoading: Bool = false
        @Published var error: Error?
        @Published var authCode: String?
        
        let urApiService: UrApiServiceProtocol
        
        init(urApiService: UrApiServiceProtocol) {
            self.urApiService = urApiService
        }
        
        func createAuthCode() async throws {
            
            if isLoading {
                return
            }
            self.isLoading = true
            self.authCode = nil
            
            do {
                let createAuthCodeResult = try await urApiService.createAuthCode()
                print("createAuthCodeResult.authCode: \(createAuthCodeResult.authCode)")
                self.authCode = createAuthCodeResult.authCode
                self.isLoading = false
            } catch (let error) {
                print("error creating auth code: \(error)")
                self.isLoading = false
            }
            
        }
        
    }
    
}
