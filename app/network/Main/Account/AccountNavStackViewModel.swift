//
//  AccountViewModel.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2024/12/10.
//

import Foundation
import URnetworkSdk

enum AccountNavigationPath: Hashable {
    case profile
    case settings
    case wallets
    case wallet(_ wallet: SdkAccountWallet)
}

extension AccountNavStackView {
    
    class ViewModel: ObservableObject {
        
        @Published var navigationPath: [AccountNavigationPath] = []
        
        func navigate(_ path: AccountNavigationPath) {
            navigationPath.append(path)
        }

        func back() {
            if !navigationPath.isEmpty {
             navigationPath.removeLast()
            }
        }
        
    }
    
}
