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
    case createNetwork(_ authLoginArgs: SdkAuthLoginArgs)
    case verify(_ userAuth: String)
    case resetPassword(_ userAuth: String)
    case seedphrase
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
