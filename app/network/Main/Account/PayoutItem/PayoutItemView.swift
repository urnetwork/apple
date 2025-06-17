//
//  PayoutItemView.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 6/17/25.
//

import SwiftUI
import URnetworkSdk

struct PayoutItemView: View {
    
    var navigate: (AccountNavigationPath) -> Void
    var payment: SdkAccountPayment
    var accountPoint: SdkAccountPoint?
    
    var body: some View {
        Text(/*@START_MENU_TOKEN@*/"Hello, World!"/*@END_MENU_TOKEN@*/)
    }
}

//#Preview {
//    PayoutItemView()
//}
