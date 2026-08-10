//
//  UrTextField.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2024/11/20.
//

import SwiftUI

struct UrTextField: View {
    
    @EnvironmentObject var themeManager: ThemeManager
    
    @Binding var text: String
    @FocusState private var isFocused: Bool
    
    // text field label
    var label: LocalizedStringKey
    
    // placeholder text
    var placeholder: LocalizedStringKey
    
    // adds supporting text below the text field divider
    var supportingText: LocalizedStringKey?
    
    // field is enabled
    var isEnabled: Bool = true
    
    // input is correct
    var validationState: ValidationState?

    var onTextChange: ((String) -> Void)?

    #if os(iOS)
    // keyboard type
    var keyboardType: UIKeyboardType = .default
    #endif
    
    // submit label
    var submitLabel: SubmitLabel = .return

    var onSubmit: (() -> Void)?
    
    var isSecure: Bool = false
    
    var disableCapitalization: Bool = false

    var accessibilityIdentifier: String = ""
    
    #if os(iOS)
    private var autoCapitalization: TextInputAutocapitalization {
        
        if (disableCapitalization) {
            return .never
        } else {
            switch keyboardType {
            case .emailAddress:
                return .never
            default:
                return .sentences
            }
        }
    
    }
    #endif
    
    #if os(iOS)
    private var shouldDisableAutocorrection: Bool {
        switch keyboardType {
        case .emailAddress:
            return true
        default:
            return false
        }
    }
    #endif
    
    private var foregroundSupportColor: Color {
        
        if (validationState != nil) {
            
            if validationState == .invalid {
                return themeManager.currentTheme.dangerColor
            }
            
            return themeManager.currentTheme.textMutedColor
            
        } else {
            return themeManager.currentTheme.textMutedColor
        }
        
    }

    var body: some View {
        VStack(alignment: .leading) {
            
            UrLabel(
                text: label,
                foregroundColor: foregroundSupportColor
            )
            
            // textfield row
            HStack {
                
                if isSecure {
                    
                    #if os(iOS)
                    
                    SecureField(
                        "",
                        text: $text,
                        prompt: Text(placeholder)
                            .font(themeManager.currentTheme.bodyFont)
                            .foregroundColor(themeManager.currentTheme.textFaintColor)
                    )
                    .tint(themeManager.currentTheme.textColor)
                    .submitLabel(submitLabel)
                    .onSubmit {
                        onSubmit?()
                    }
                    .keyboardType(keyboardType)
                    .textInputAutocapitalization(autoCapitalization)
                    .disableAutocorrection(shouldDisableAutocorrection)
                    .foregroundColor(themeManager.currentTheme.textColor)
                    .disabled(!isEnabled)
                    .focused($isFocused)
                    .onChange(of: text) { newValue in
                        onTextChange?(newValue)
                    }
                    .accessibilityIdentifier(accessibilityIdentifier)
                    
                    #else
                    
                    SecureField(
                        "",
                        text: $text,
                        prompt: Text(placeholder)
                            .font(themeManager.currentTheme.bodyFont)
                            .foregroundColor(themeManager.currentTheme.textFaintColor)
                    )
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(themeManager.currentTheme.tintedBackgroundBase)
                    .cornerRadius(4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(
                                isFocused
                                ? themeManager.currentTheme.textMutedColor
                                : themeManager.currentTheme.borderBaseColor,
                                lineWidth: 1
                            )
                    )
                    .tint(themeManager.currentTheme.textColor)
                    .submitLabel(submitLabel)
                    .onSubmit {
                        onSubmit?()
                    }
                    .foregroundColor(themeManager.currentTheme.textColor)
                    .disabled(!isEnabled)
                    .focused($isFocused)
                    .onChange(of: text) { newValue in
                        onTextChange?(newValue)
                    }
                    .accessibilityIdentifier(accessibilityIdentifier)
                    
                    #endif
                    
                } else {
                    
                    #if os(iOS)
                    
                    TextField(
                        "",
                        text: $text,
                        prompt: Text(placeholder)
                            .font(themeManager.currentTheme.bodyFont)
                            .foregroundColor(themeManager.currentTheme.textFaintColor)
                    )
                    .tint(themeManager.currentTheme.textColor)
                    .submitLabel(submitLabel)
                    .onSubmit {
                        onSubmit?()
                    }
                    .keyboardType(keyboardType)
                    .textInputAutocapitalization(autoCapitalization)
                    .disableAutocorrection(shouldDisableAutocorrection)
                    .foregroundColor(themeManager.currentTheme.textColor)
                    .disabled(!isEnabled)
                    .focused($isFocused)
                    .onChange(of: text) { newValue in
                        onTextChange?(newValue)
                    }
                    .accessibilityIdentifier(accessibilityIdentifier)
                    
                    #elseif os(macOS)
                    
                    TextField(
                        "",
                        text: $text,
                        prompt: Text(placeholder)
                            .font(themeManager.currentTheme.bodyFont)
                            .foregroundColor(themeManager.currentTheme.textFaintColor)
                    )
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(themeManager.currentTheme.tintedBackgroundBase)
                    .cornerRadius(4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(
                                isFocused
                                ? themeManager.currentTheme.textMutedColor
                                : themeManager.currentTheme.borderBaseColor,
                                lineWidth: 1
                            )
                    )
                    .tint(themeManager.currentTheme.textColor)
                    .submitLabel(submitLabel)
                    .onSubmit {
                        onSubmit?()
                    }
                    .foregroundColor(themeManager.currentTheme.textColor)
                    .disabled(!isEnabled)
                    .focused($isFocused)
                    .onChange(of: text) { newValue in
                        onTextChange?(newValue)
                    }
                    .accessibilityIdentifier(accessibilityIdentifier)
                    
                    #endif
                    
                }
                
                if (validationState != nil) {
                    
                    if validationState == .invalid {
                        Image("ur.symbols.warning")
                            .foregroundColor(themeManager.currentTheme.dangerColor)
                    }
                    
                    if validationState == .validating {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle())
                            .frame(height: 24)
                    }
                }
            }
            .frame(height: 24)
        
            #if os(iOS)
            // divider
            if (isEnabled) {
                Divider()
                    .background(isFocused
                                ? themeManager.currentTheme.borderStrongColor :themeManager.currentTheme.borderBaseColor)
            }
            #endif
        
            // should we show supporting text if input is disabled?
            if let supportingText {
                Text(supportingText)
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(foregroundSupportColor)
            }
        }
    }
}

private struct UrTextFieldPreview: View {
    @State private var emptyValue = ""
    @State private var sampleValue = "lorem@ipsum.com"
    
    private let themeManager = ThemeManager.shared
    
    var body: some View {
        VStack {
            // empty text field
            UrTextField(
                text: $emptyValue,
                label: "Your email",
                placeholder: "Placeholder"
            )

            Spacer()
                .frame(height: 32)

            // populated
            UrTextField(
                text: $sampleValue,
                label: "Your email",
                placeholder: "Placeholder"
            )

            Spacer()
                .frame(height: 32)

            // populated with supporting text
            UrTextField(
                text: $sampleValue,
                label: "Your email",
                placeholder: "Placeholder",
                supportingText: "Network names must be 6 characters or more"
            )

            Spacer()
                .frame(height: 32)

            // error exists
            UrTextField(
                text: $sampleValue,
                label: "Your email",
                placeholder: "Placeholder",
                supportingText: "Network name is too short. Try one with at least 6 characters",
                validationState: ValidationState.invalid
            )

            Spacer()
                .frame(height: 32)

            // disabled input
            UrTextField(
                text: $sampleValue,
                label: "Your email",
                placeholder: "Placeholder",
                isEnabled: false,
                validationState: ValidationState.valid
            )
        }
        .environmentObject(themeManager)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .background(themeManager.currentTheme.backgroundColor)
    }
}

#Preview {
    UrTextFieldPreview()
}
