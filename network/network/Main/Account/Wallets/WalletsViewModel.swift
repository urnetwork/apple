//
//  WalletsViewModel.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2024/12/17.
//

import Foundation

extension WalletsView {
    
    @MainActor
    class ViewModel: ObservableObject {
        
        @Published var displayExternalWalletSheet: Bool = false

        let domain = "[WalletsViewModel]"
        
        init() {}
        
    }
    
}
