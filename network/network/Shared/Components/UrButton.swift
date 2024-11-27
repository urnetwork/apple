//
//  UrButton.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2024/11/21.
//

import SwiftUI

enum UrButtonStyle {
    case primary
    case secondary
    case outlinePrimary
    case outlineSecondary
}

struct UrButton: View {
    
    @EnvironmentObject var themeManager: ThemeManager
    
    var text: LocalizedStringKey
    var onClick: () -> Void
    var style: UrButtonStyle = .primary
    var enabled: Bool = true
    var isFullWidth: Bool = true
    var trailingIcon: String?
    
    var body: some View {
        
        Button(action: {
            onClick()
        }) {
            HStack {
                Text(text)
                    .foregroundColor(foregroundColor)
                    .font(
                        Font.custom("PP NeueBit", size: 24)
                        .weight(.bold)
                    )
                
                if let trailingIcon {
                    Image(trailingIcon)
                    // UrImage(path: trailingIconPath)
                }
            }
            .frame(maxWidth: isFullWidth ? .infinity : nil)
            .frame(height: 48)
            .padding(.horizontal, 32)
        }
        .background(backgroundColor)
        .cornerRadius(100)
        .overlay(
            RoundedRectangle(cornerRadius: 100)
                .stroke(borderColor, lineWidth: borderWidth)
        )
        .opacity(opacity)
        .disabled(!enabled)
    }
    
    private var backgroundColor: Color {
        switch style {
        case .primary:
            return themeManager.currentTheme.accentColor
        case .secondary:
            return .white
        case .outlinePrimary, .outlineSecondary:
            return Color.clear
        }
    }
    
    private var foregroundColor: Color {
        switch style {
        case .primary:
            return .white
        case .secondary:
            return .urBlack
        case .outlinePrimary:
            return .urBlack
        case .outlineSecondary:
            return themeManager.currentTheme.textMutedColor
        }
    }
    
    private var borderWidth: CGFloat {
        if style == .outlinePrimary || style == .outlineSecondary {
            return 1
        } else {
            return 0
        }
    }
    
    private var opacity: Double {
        if enabled {
            1
        } else {
            0.3
        }
    }
    
    private var borderColor: Color {
        if style == .outlinePrimary {
            .urBlack
        } else if style == .outlineSecondary {
            themeManager.currentTheme.borderEmphasisColor
        } else {
            .clear
        }
    }
}


#Preview {
    
    var themeManager = ThemeManager.shared
    
    VStack {
        // primary
        UrButton(
            text: "Primary button", onClick: {}
        )
        
        Spacer()
            .frame(height: 32)
        
        // primary disabled
        UrButton(
            text: "Primary button disabled",
            onClick: {},
            enabled: false
        )
        
        Spacer()
            .frame(height: 32)
        
        // secondary
        UrButton(
            text: "Secondary button",
            onClick: {},
            style: UrButtonStyle.secondary
        )
        
        Spacer()
            .frame(height: 32)
        
        VStack {
            // outline primary
            // has a black border, so we add a background color for visibility
            UrButton(
                text: "Outline primary",
                onClick: {},
                style: UrButtonStyle.outlinePrimary
            )
            
            Spacer()
                .frame(height: 32)
            
            // disabled outline primary
            UrButton(
                text: "Outline primary disabled",
                onClick: {},
                style: UrButtonStyle.outlinePrimary,
                enabled: false
            )
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(.urGreen)
        
        Spacer()
            .frame(height: 32)
        
        // outline secondary
        UrButton(
            text: "Outline secondary",
            onClick: {},
            style: UrButtonStyle.outlineSecondary
        )
        
        Spacer()
            .frame(height: 32)
        
        // outline secondary - full width false
        UrButton(
            text: "Outline secondary",
            onClick: {},
            style: UrButtonStyle.outlineSecondary,
            isFullWidth: false
        )
    }
    .environmentObject(themeManager)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding()
    .background(themeManager.currentTheme.backgroundColor)
    
}
