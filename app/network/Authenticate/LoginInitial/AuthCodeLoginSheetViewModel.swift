//
//  AuthCodeLoginSheetViewModel.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2/21/26.
//

import Foundation
import URnetworkSdk

extension AuthCodeLoginSheet {
    
    @MainActor
    class ViewModel: ObservableObject {
        
        private var urApiService: UrApiServiceProtocol
        
        @Published var authCode: String = ""
        
        @Published private(set) var isLoading: Bool = false
        
        @Published private(set) var loginFailed: Bool = false
        
        init(urApiService: UrApiServiceProtocol) {
            self.urApiService = urApiService
        }
        
        func authCodeLogin() async -> Result<SdkAuthCodeLoginResult, Error> {
            
            if (self.isLoading) {
                return .failure(LoginError.inProgress)
            }
            
            let args = SdkAuthCodeLoginArgs()
            args.authCode = self.authCode
            
            do {
                self.isLoading = true
                
                let result = try await urApiService.authCodeLogin(args)
                
                self.isLoading = false
                self.loginFailed = false
                
                return .success(result)
                
            } catch {
                self.isLoading = false
                self.loginFailed = true
                return .failure(error)
            }
        }
    }
}
