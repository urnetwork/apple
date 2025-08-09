//
//  DePinHubSettingsLinkRow.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 8/9/25.
//

import SwiftUI

struct DePinHubSettingsLinkRow: View {
    
    @EnvironmentObject var themeManager: ThemeManager
    let depinHubLink = "https://depinhub.io/projects/urnetwork"
    
    var body: some View {
        HStack {
            
            Image("DePinHub")
                .resizable()
                .scaledToFit()
                .frame(width: 24, height: 24)
            
            Spacer().frame(width: 4)
            
            Text(
                // note - we don't pass in depinHubLink to the markdown since it breaks in macOS
                "Verified project on [DePIN Hub](https://depinhub.io/projects/urnetwork)"
            )
                .font(themeManager.currentTheme.bodyFont)
                .foregroundColor(themeManager.currentTheme.textColor)
            
            Spacer()
            
            Button(action: {
                if let url = URL(string: depinHubLink) {
                    
                    #if canImport(UIKit)
                    UIApplication.shared.open(url, options: [:], completionHandler: nil)
                    #endif
                    
                    #if canImport(AppKit)
                    NSWorkspace.shared.open(url)
                    #endif
                    
                }
            }) {
                Image(systemName: "arrow.forward")
                #if os(iOS)
                    .foregroundColor(themeManager.currentTheme.textMutedColor)
                #endif
            }
        }
    }
}

#Preview {
    DePinHubSettingsLinkRow()
}
