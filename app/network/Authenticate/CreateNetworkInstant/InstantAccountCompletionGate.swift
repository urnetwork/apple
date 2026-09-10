//
//  InstantAccountCompletionGate.swift
//  URnetwork
//

/// Admits the seedphrase confirmation exactly once. Dismissing the SwiftUI
/// cover is asynchronous, so the button can otherwise deliver a second tap
/// while the first client registration is still running.
struct InstantAccountCompletionGate {
    private(set) var isCompleting = false

    mutating func takeCreatedLogin(jwt: String) -> NetworkLogin? {
        guard !isCompleting else {
            return nil
        }
        isCompleting = true
        return .created(jwt)
    }
}
