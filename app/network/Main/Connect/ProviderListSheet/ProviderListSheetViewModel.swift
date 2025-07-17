//
//  ProviderListSheetViewModel.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2025/01/12.
//

import Foundation
import SwiftUI

@MainActor
class ProviderListSheetViewModel: ObservableObject {

    @Published var isPresented: Bool = false
    @Published private(set) var isRefreshing: Bool = false
    
    func setIsRefreshing(_ isRefreshing: Bool) {
        self.isRefreshing = isRefreshing
    }
    
}
