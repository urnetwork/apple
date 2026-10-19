//
//  LoginSeedphraseViewModel.swift
//  URnetwork
//

import Foundation
import URnetworkSdk

extension LoginSeedphraseView {

    @MainActor
    class ViewModel: ObservableObject {

        private let urApiService: UrApiServiceProtocol

        @Published var seedphrase: String = "" {
            didSet {
                errorMessage = nil
            }
        }

        @Published private(set) var wordCountWarning: String?

        @Published private(set) var isLoggingIn: Bool = false

        @Published var errorMessage: String?

        let domain = "LoginSeedphraseViewModel"

        init(urApiService: UrApiServiceProtocol) {
            self.urApiService = urApiService
        }

        func setErrorMessage(_ message: String?) {
            errorMessage = message
        }

        var isSeedphraseValid: Bool {
            wordCount == 12 || wordCount == 24
        }

        var normalizedSeedphrase: String {
            seedphrase
                .lowercased()
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }

        var wordCount: Int {
            normalizedSeedphrase.isEmpty ? 0 : normalizedSeedphrase.components(separatedBy: " ").count
        }

        func validateWordCount() -> Bool {
            let count = wordCount
            if count == 12 || count == 24 {
                wordCountWarning = nil
                return true
            }
            if count > 0 {
                wordCountWarning = "Seedphrase should be 12 or 24 words (you entered \(count))"
            } else {
                wordCountWarning = nil
            }
            return false
        }

        func login(request: NetworkLoginRequest? = nil) async -> AuthLoginResult {

            if let request, !request.isCurrent { return .failure(CancellationError()) }
            if isLoggingIn {
                return .failure(NSError(domain: domain, code: 0, userInfo: [NSLocalizedDescriptionKey: "Login already in progress"]))
            }

            guard isSeedphraseValid else {
                return .failure(NSError(domain: domain, code: 0, userInfo: [NSLocalizedDescriptionKey: "Seedphrase should be 12 or 24 words"]))
            }

            validateWordCount()

            isLoggingIn = true
            errorMessage = nil

            defer {
                if request?.isCurrent != false { isLoggingIn = false }
            }

            do {
                let result = try await urApiService.loginWithSeedphrase(seedphrase: normalizedSeedphrase)
                guard request?.isCurrent != false else { return .failure(CancellationError()) }
                return result
            } catch {
                guard request?.isCurrent != false else { return .failure(CancellationError()) }
                return .failure(error)
            }

        }

    }

}
