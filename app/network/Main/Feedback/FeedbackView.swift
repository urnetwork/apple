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
    @EnvironmentObject var deviceManager: DeviceManager
    
    init(urApiService: UrApiServiceProtocol) {
        _viewModel = StateObject.init(wrappedValue: ViewModel(
            urApiService: urApiService
        ))
    }
    
    
    
    var body: some View {
        
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading) {
                    
                    Text("Get in touch")
                        .font(themeManager.currentTheme.titleFont)
                        .foregroundColor(themeManager.currentTheme.textColor)
                    
                    Spacer().frame(height: 64)
                    
                    Text("Send us your feedback directly or [join our Discord](https://discord.com/invite/RUNZXMwPRK) for direct support.")
                        .foregroundColor(themeManager.currentTheme.textColor)
                    
                    Spacer().frame(height: 32)
                    
                    UrLabel(text: "Feedback")
                    
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
                    
                    Toggle(isOn: $viewModel.attachLogs) {
                        Text("Attach logs to feedback (optional)")
                            .font(themeManager.currentTheme.bodyFont)
                    }
                    
                    ExportLogsButton()
                    
                    Spacer().frame(height: 16)
        
                    
                    UrLabel(text: "How are we doing?")
                    
                    Spacer().frame(height: 8)
                    
                    // Stars rating
                    HStack(alignment: .center) {
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
                    .frame(maxWidth: .infinity)
                    
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
    
    private func handleSendFeedbackResult(_ result: Result<SdkFeedbackSendResult, Error>) {
        
        
        #if canImport(UIKit)
        hideKeyboard()
        #endif
        
        
        switch result {
        case .success(let result):
            
            // TODO: message sent overlay
            
            snackbarManager.showSnackbar(message: "Sent! Thanks for your feedback.")
            
            requestReview()
            
            viewModel.setStarCount(0)
            
            if viewModel.attachLogs, let feedbackIdStr = result.feedbackId?.idStr {
                do {
                    try deviceManager.uploadLogs(feedbackId: feedbackIdStr)
                } catch(let err) {
                    print("error uploading logs: \(err)")
                }
            }

        case .failure:
            snackbarManager.showSnackbar(message: "There was an error sending your feedback. Please try again later.")
        }
    }
}

#Preview {
    FeedbackView(
        urApiService: MockUrApiService()
    )
    .environmentObject(ThemeManager.shared)
}
