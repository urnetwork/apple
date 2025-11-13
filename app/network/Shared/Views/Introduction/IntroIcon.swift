//
//  IntroIcon.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 11/13/25.
//

import SwiftUI

struct IntroIcon: View {
    var body: some View {
        HStack(alignment: .center) {
            Image("Icon")
                .resizable()
                .frame(width: 64, height: 64)
        }
        .frame(maxWidth: .infinity)
    }
}

#Preview {
    IntroIcon()
}
