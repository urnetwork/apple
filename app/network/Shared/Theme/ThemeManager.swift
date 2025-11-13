//
//  ThemeManager.swift
//  network
//
//  Created by Stuart Kuentzel on 2024/11/20.
//

import Foundation
import SwiftUI



final class ThemeManager: ObservableObject {
    @Published var currentTheme: Theme = Theme.dark
    
    static let shared = ThemeManager()
    
    private init() {}
}

extension Theme {
    
    #if os(iOS)
    static let dark = Theme(
        backgroundColor: Color("UrBlack"),
        tintedBackgroundBase: Color(red: 0.11, green: 0.11, blue: 0.11),

        accentColor: Color("UrElectricBlue"),
        dangerColor: Color("UrCoral"),
        
        textColor: Color.white,
        inverseTextColor: Color("UrBlack"),
        textMutedColor: Color(red: 0.6, green: 0.6, blue: 0.6),
        textFaintColor: Color(red: 0.35, green: 0.35, blue: 0.35),
        
        borderBaseColor: .white.opacity(0.12),
        borderStrongColor: Color(red: 1, green: 1, blue: 1, opacity: 0.8),
        borderEmphasisColor: Color(red: 1, green: 1, blue: 1, opacity: 0.24),
        
        titleFont: Font.custom("ABCGravity-Extended", size: 32),
        titleCondensedFont: Font.custom("ABCGravity-ExtraCondensed", size: 32),
        secondaryTitleFont: Font.custom("ABCGravity-Extended", size: 24),
        
        bodyFont: Font.custom("PPNeueMontreal-Regular", size: 16),
        bodyFontLarge: Font.custom("PP NeueBit", size: 28).bold(),
        secondaryBodyFont: Font.custom("PPNeueMontreal-Regular", size: 14),
        toolbarTitleFont: Font.custom("PP NeueBit", size: 24)
    )
    #elseif os(macOS)
    static let dark = Theme(
        backgroundColor: Color("UrBlack"),
        tintedBackgroundBase: Color(red: 0.11, green: 0.11, blue: 0.11),

        accentColor: Color("UrElectricBlue"),
        dangerColor: Color("UrCoral"),
        
        textColor: Color.white,
        inverseTextColor: Color("UrBlack"),
        textMutedColor: Color(red: 0.6, green: 0.6, blue: 0.6),
        textFaintColor: Color(red: 0.35, green: 0.35, blue: 0.35),
        
        borderBaseColor: .white.opacity(0.12),
        borderStrongColor: Color(red: 1, green: 1, blue: 1, opacity: 0.8),
        borderEmphasisColor: Color(red: 1, green: 1, blue: 1, opacity: 0.24),
        
        titleFont: Font.custom("ABCGravity-Extended", size: 32),
        titleCondensedFont: Font.custom("ABCGravity-ExtraCondensed", size: 32),
        secondaryTitleFont: Font.custom("ABCGravity-Extended", size: 24),
        
        bodyFont: Font.custom("PPNeueMontreal-Regular", size: 14),
        secondaryBodyFont: Font.custom("PPNeueMontreal-Regular", size: 12),
        toolbarTitleFont: Font.custom("PP NeueBit", size: 24)
    )
    #endif
}
