//
//  LoginAuthCodeViewModel.swift
//  URnetwork
//

import Foundation
import URnetworkSdk

extension LoginAuthCodeView {

    @MainActor
    class ViewModel: ObservableObject {

        private var urApiService: UrApiServiceProtocol

        @Published var authCode: String = "" {
            didSet {
                loginFailed = false
            }
        }

        @Published private(set) var isLoading: Bool = false

        @Published private(set) var loginFailed: Bool = false

        init(urApiService: UrApiServiceProtocol) {
            self.urApiService = urApiService
        }

        func authCodeLogin(request: NetworkLoginRequest? = nil) async -> Result<SdkAuthCodeLoginResult, Error> {

            if let request, !request.isCurrent { return .failure(CancellationError()) }
            if self.isLoading {
                return .failure(LoginError.inProgress)
            }

            let args = SdkAuthCodeLoginArgs()
            args.authCode = self.authCode

            do {
                self.isLoading = true

                let result = try await urApiService.authCodeLogin(args)
                guard request?.isCurrent != false else { return .failure(CancellationError()) }

                self.isLoading = false
                self.loginFailed = false

                return .success(result)

            } catch {
                guard request?.isCurrent != false else { return .failure(CancellationError()) }
                self.isLoading = false
                self.loginFailed = true
                return .failure(error)
            }
        }
    }
}
