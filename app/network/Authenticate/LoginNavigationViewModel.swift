//
//  LoginNavigationViewModel.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2024/11/21.
//

import Foundation
import URnetworkSdk

enum LoginInitialNavigationPath: Hashable {
    // case initial
    case password(_ userAuth: String)
    // `bittensorWalletId`: the Bittensor wallet that signed the create's wallet
    // auth, named when the server refuses a signature from another account
    case createNetwork(_ authLoginArgs: SdkAuthLoginArgs, bittensorWalletId: String? = nil)
    // `sendNotice` is whether the server sent the code
    case verify(_ userAuth: String, sendNotice: VerifySendNotice)
    case resetPassword(_ userAuth: String)
    case seedphrase
    case authCode
    case createInstant
}

extension LoginNavigationView {
    
    @MainActor
    class ViewModel: ObservableObject {
        
        @Published var navigationPath: [LoginInitialNavigationPath] = []
        
        func navigate(_ path: LoginInitialNavigationPath) {
            navigationPath.append(path)
        }

        // can be used in custom back button        
        func back() {
            if !navigationPath.isEmpty {
                navigationPath.removeLast()
            }
        }
        
        func backToRoot() {
            navigationPath.removeAll()
        }
    }
}
