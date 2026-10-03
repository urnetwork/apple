//
//  UrSnackBar.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2024/12/07.
//

import SwiftUI

struct UrSnackBar: View {

    @EnvironmentObject var themeManager: ThemeManager

    var message: String
    var isVisible: Bool
    /// A tap on the message, to dismiss it early.
    var onTap: (() -> Void)? = nil

    var body: some View {

        VStack {
            Spacer()

            Text(message)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.urNavyBlue)
                .font(themeManager.currentTheme.bodyFont)
                .foregroundColor(.white)
                .cornerRadius(8)
                .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 5)
                .onTapGesture {
                    onTap?()
                }
                .offset(y: isVisible ? 48 : 180)
                .animation(.easeInOut(duration: 0.3), value: isVisible)
                .zIndex(10)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .edgesIgnoringSafeArea(.bottom)

    }
}

#Preview {
    UrSnackBar(
        message: "Sample message",
        isVisible: true
    )
}
