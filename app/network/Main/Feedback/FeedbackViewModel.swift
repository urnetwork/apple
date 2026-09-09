//
//  FeedbackViewModel.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2024/12/10.
//

import Foundation
import URnetworkSdk

extension FeedbackView {
    
    @MainActor
    class ViewModel: ObservableObject {
        
        @Published var feedback: String = ""
        @Published private(set) var isSending: Bool = false
        @Published private(set) var starCount: Int? = nil
        @Published var attachLogs: Bool = false
        /// The reason an email's one-tap answer carried, for the feedback event.
        private(set) var prefilledReason: String = ""
        
        let domain = "[FeedbackViewModel]"
        
        var urApiService: UrApiServiceProtocol
        
        init(urApiService: UrApiServiceProtocol) {
            self.urApiService = urApiService
        }
        
        
        
        func setStarCount(_ starCount: Int) {
            self.starCount = starCount
        }

        /// Starts the screen from an email's one-tap answer: the rating as stars,
        /// the reason as the text (only when nothing has been typed yet).
        func apply(_ prefill: FeedbackPrefill) {
            if let rating = prefill.rating {
                starCount = rating
            }
            if let reason = prefill.reason {
                prefilledReason = reason
                if feedback.isEmpty, let text = prefill.reasonText {
                    feedback = text
                }
            }
        }
        
        func sendFeedback() async -> Result<SdkFeedbackSendResult, Error> {
            
            if isSending {
                return .failure(SendFeedbackError.isSending)
            }
            self.isSending = true
            
            do {
                
                let result = try await urApiService.sendFeedback(feedback: self.feedback, starCount: self.starCount ?? 0)

                ClientEvents.shared.feedbackSubmitted(
                    rating: self.starCount ?? 0,
                    reason: self.prefilledReason,
                    text: self.feedback
                )
                
                self.feedback = ""
                self.prefilledReason = ""
                self.isSending = false
                
                return .success(result)
                
                
            } catch(let error) {
                print("\(domain) Error sending feedback: \(error)")
                self.isSending = false
                return .failure(error)
            }
            
        }
        
    }
    
}
