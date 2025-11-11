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
    var action: () -> Void
    var style: UrButtonStyle = .primary
    var enabled: Bool = true
    var isFullWidth: Bool = true
    var trailingIcon: String?
    var isProcessing: Bool = false
    
    var body: some View {
        
        Button(action: {
            action()
        }) {
            HStack {
                
                if isProcessing {
                    ProgressView()
                        .tint(.white)
                } else {
                    Text(text)
                        .foregroundColor(foregroundColor)
                        .font(
                            themeManager.currentTheme.toolbarTitleFont.bold()
                        )
                    
                    if let trailingIcon {
                        Image(trailingIcon)
                    }
                }
                
            }
            .frame(maxWidth: isFullWidth ? .infinity : nil)
            .frame(height: 48)
            .padding(.horizontal, 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(backgroundColor)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
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
            text: "Primary button",
            action: {}
        )
        
        Spacer()
            .frame(height: 32)
        
        // primary disabled
        UrButton(
            text: "Primary button disabled",
            action: {},
            enabled: false
        )
        
        Spacer()
            .frame(height: 32)
        
        // secondary
        UrButton(
            text: "Secondary button",
            action: {},
            style: UrButtonStyle.secondary
        )
        
        Spacer()
            .frame(height: 32)
        
        VStack {
            // outline primary
            // has a black border, so we add a background color for visibility
            UrButton(
                text: "Outline primary",
                action: {},
                style: UrButtonStyle.outlinePrimary
            )
            
            Spacer()
                .frame(height: 32)
            
            // disabled outline primary
            UrButton(
                text: "Outline primary disabled",
                action: {},
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
            action: {},
            style: UrButtonStyle.outlineSecondary
        )
        
        Spacer()
            .frame(height: 32)
        
        // outline secondary - full width false
        UrButton(
            text: "Outline secondary",
            action: {},
            style: UrButtonStyle.outlineSecondary,
            isFullWidth: false
        )
        
        // is processing
        UrButton(
            text: "Processing",
            action: {},
            isProcessing: true
        )
    }
    .environmentObject(themeManager)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding()
    .background(themeManager.currentTheme.backgroundColor)
    
}
