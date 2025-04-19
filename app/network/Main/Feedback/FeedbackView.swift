//
//  FeedbackView.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2024/12/10.
//

import SwiftUI
import URnetworkSdk

struct FeedbackView: View {
    
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var snackbarManager: UrSnackbarManager
    @StateObject private var viewModel: ViewModel
    @Environment(\.requestReview) private var requestReview
    @FocusState private var isFocused: Bool
    
    init(api: SdkApi?) {
        _viewModel = StateObject.init(wrappedValue: ViewModel(
            api: api
        ))
    }
    
    var body: some View {
        
        GeometryReader { geometry in
            ScrollView {
                VStack {
                    HStack {
                        Text("Get in touch")
                            .font(themeManager.currentTheme.titleFont)
                            .foregroundColor(themeManager.currentTheme.textColor)
                        Spacer()
                    }
                    .frame(height: 32)
                    
                    Spacer().frame(height: 64)
                    
                    HStack {
                        Text("Send us your feedback directly or [join our Discord](https://discord.com/invite/RUNZXMwPRK) for direct support.")
                        
                        Spacer()
                    }
                    .foregroundColor(themeManager.currentTheme.textColor)
                    
                    Spacer().frame(height: 32)
                    
                    HStack {
                        UrLabel(text: "Feedback")
                        Spacer()
                    }
                    
                    TextEditor(
                        text: $viewModel.feedback
                    )
                    .padding(.horizontal, 4)
                    .frame(height: 100)
                    .disabled(viewModel.isSending)
                    .scrollContentBackground(.hidden)
                    .background(themeManager.currentTheme.tintedBackgroundBase)
                    .cornerRadius(8)
                    .focused($isFocused)
                    .foregroundColor(themeManager.currentTheme.textColor)
                    
                    Spacer().frame(height: 16)
                    
                    HStack {
                        UrLabel(text: "How are we doing?")
                        Spacer()
                    }
                    
                    Spacer().frame(height: 8)
                    
                    // Stars rating
                    HStack {
                        ForEach(1...5, id: \.self) { index in
                            Spacer().frame(width: 8)
                            Image(systemName: index <= (viewModel.starCount ?? 0) ? "star.fill" : "star")
                                .foregroundColor(.urLightYellow)
                                .font(.system(size: 32))
                                .onTapGesture {
                                    viewModel.setStarCount(index)
                                }
                            Spacer().frame(width: 8)
                        }
                    }
                    
                    // This spacer will push the button to the bottom
                    Spacer(minLength: 20)
                    
                    UrButton(
                        text: "Send",
                        action: {
                            Task {
                                let result = await viewModel.sendFeedback()
                                self.handleSendFeedbackResult(result)
                            }
                        },
                        enabled: !viewModel.isSending && (!viewModel.feedback.isEmpty || (viewModel.starCount ?? 0) > 0)
                    )
                }
                .padding()
                .frame(maxWidth: 600)
                .frame(minHeight: geometry.size.height)
                .background(themeManager.currentTheme.backgroundColor)
                .onTapGesture {
                    isFocused = false
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        
    }
    
    private func handleSendFeedbackResult(_ result: Result<Void, Error>) {
        
        
        #if canImport(UIKit)
        hideKeyboard()
        #endif
        
        
        switch result {
        case .success:
            
            // TODO: message sent overlay
            
            snackbarManager.showSnackbar(message: "Sent! Thanks for your feedback.")
            
            if viewModel.starCount == 5 {
                requestReview()
            }
            
            viewModel.setStarCount(0)
            
        case .failure:
            snackbarManager.showSnackbar(message: "There was an error sending your feedback. Please try again later.")
        }
    }
}

#Preview {
    FeedbackView(
        api: nil
    )
    .environmentObject(ThemeManager.shared)
}
