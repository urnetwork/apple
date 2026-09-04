//
//  AccountPreferencesViewModel.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2024/12/14.
//

import Foundation
import URnetworkSdk

private class GetAccountPreferencesCallback: SdkCallback<SdkAccountPreferencesGetResult, SdkAccountPreferencesGetCallbackProtocol>, SdkAccountPreferencesGetCallbackProtocol {
    func result(_ result: SdkAccountPreferencesGetResult?, err: Error?) {
        handleResult(result, err: err)
    }
}

private class UpdateAccountPreferencesCallback: SdkCallback<SdkAccountPreferencesSetResult, SdkAccountPreferencesSetCallbackProtocol>, SdkAccountPreferencesSetCallbackProtocol {
    func result(_ result: SdkAccountPreferencesSetResult?, err: Error?) {
        handleResult(result, err: err)
    }
}

@MainActor
class AccountPreferencesViewModel: ObservableObject {
    
    private var isLoadingPreferences = true
    private var isApplyingPreferenceState = false
    private var lastSavedCanReceiveProductUpdates = false

    @Published var canReceiveProductUpdates: Bool = false {
        didSet {
            guard !isLoadingPreferences, !isApplyingPreferenceState else { return }
            guard oldValue != canReceiveProductUpdates else { return }
            self.updateAccountPreferences(canReceiveProductUpdates, previousValue: oldValue)
        }
    }
    
    @Published var isUpdatingAccountPreferences: Bool = false
    @Published private(set) var saveErrorMessage: String?

    func clearSaveErrorMessage() {
        // called from the settings view's observer of this value
        guard saveErrorMessage != nil else { return }
        saveErrorMessage = nil
    }

    let domain = "AccountPreferencesViewModel"
    
    var api: SdkApi?
    
    init(api: SdkApi?) {
        self.api = api
        self.fetchAccountPreferences()
    }
    
    private func fetchAccountPreferences() {
        
        Task {
        
            do {
                
                let result: SdkAccountPreferencesGetResult = try await withCheckedThrowingContinuation { continuation in
                    
                    let callback = GetAccountPreferencesCallback { result, err in
                        
                        if let err = err {
                            continuation.resume(throwing: err)
                            return
                        }
                        
                        guard let result = result else {
                            continuation.resume(throwing: NSError(domain: "AccountPreferencesViewModel", code: 0, userInfo: [NSLocalizedDescriptionKey: "AccountPreferencesGetCallback result is nil"]))
                            return
                        }
                        
                        continuation.resume(returning: result)
                        return
                    }
                    
                    guard let api = self.api else {
                        continuation.resume(throwing: NSError(domain: "AccountPreferencesViewModel", code: 0, userInfo: [NSLocalizedDescriptionKey: "API not available"]))
                        return
                    }
                    api.accountPreferencesGet(callback)
                }
                
                self.lastSavedCanReceiveProductUpdates = result.productUpdates
                self.setCanReceiveProductUpdates(result.productUpdates)
                self.isLoadingPreferences = false
                
            } catch(let error) {
                print("[\(domain)] Error fetching account preferences: \(error)")
                self.isLoadingPreferences = false
            }
            
        }
        
    }
    
    private func setCanReceiveProductUpdates(_ value: Bool) {
        isApplyingPreferenceState = true
        canReceiveProductUpdates = value
        isApplyingPreferenceState = false
    }

    func updateAccountPreferences(_ allowUpdates: Bool, previousValue: Bool? = nil) {
        
        if (isUpdatingAccountPreferences) {
            setCanReceiveProductUpdates(previousValue ?? lastSavedCanReceiveProductUpdates)
            return
        }
        
        isUpdatingAccountPreferences = true
        
        Task {
         
            do {
                
                let _: SdkAccountPreferencesSetResult = try await withCheckedThrowingContinuation { continuation in
                    
                    let callback = UpdateAccountPreferencesCallback { result, err in
                        
                        if let err = err {
                            continuation.resume(throwing: err)
                            return
                        }
                        
                        guard let result = result else {
                            continuation.resume(throwing: NSError(domain: "AccountPreferencesViewModel", code: 0, userInfo: [NSLocalizedDescriptionKey: "UpdateAccountPreferencesCallback result is nil"]))
                            return
                        }
                        
                        continuation.resume(returning: result)
                        return
                    }
                    
                    let args = SdkAccountPreferencesSetArgs()
                    args.productUpdates = allowUpdates
                    
                    guard let api = self.api else {
                        continuation.resume(throwing: NSError(domain: "AccountPreferencesViewModel", code: 0, userInfo: [NSLocalizedDescriptionKey: "API not available"]))
                        return
                    }
                    api.accountPreferencesUpdate(args, callback: callback)

                }
                
                lastSavedCanReceiveProductUpdates = allowUpdates
                isUpdatingAccountPreferences = false
                
            } catch(let error) {
                
                print("[\(domain)] error updating account preferences: \(error.localizedDescription)")
                
                setCanReceiveProductUpdates(previousValue ?? lastSavedCanReceiveProductUpdates)
                isUpdatingAccountPreferences = false
                // the toggle silently snapped back to its saved value — tell the user why
                saveErrorMessage = String(localized: "Couldn't update your preferences. Please try again.")
            }
            
        }
        
    }
    
}
