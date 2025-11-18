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
        
        let domain = "[FeedbackViewModel]"
        
        var urApiService: UrApiServiceProtocol
        
        init(urApiService: UrApiServiceProtocol) {
            self.urApiService = urApiService
        }
        
        func setStarCount(_ starCount: Int) {
            self.starCount = starCount
        }
        
        func sendFeedback() async -> Result<Void, Error> {
            
            if isSending {
                return .failure(SendFeedbackError.isSending)
            }
            self.isSending = true
            
            do {
                
                let _ = try await urApiService.sendFeedback(feedback: self.feedback, starCount: self.starCount ?? 0)
                
                self.feedback = ""
                self.isSending = false
                
                return .success(())
                
                
            } catch(let error) {
                print("\(domain) Error sending feedback: \(error)")
                self.isSending = false
                return .failure(error)
            }
            
        }
        
    }
    
}
