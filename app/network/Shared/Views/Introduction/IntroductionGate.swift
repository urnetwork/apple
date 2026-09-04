//
//  IntroductionGate.swift
//  URnetwork
//

import SwiftUI

/// Decides whether the post-signup introduction is shown and records that it
/// finished.
///
/// The introduction runs once for a network created on this device. Signing
/// in arms it in memory (`introductionComplete == false`) and in the SDK's
/// persisted local state (`canPromptIntroFunnel`). Finishing or skipping it
/// has to clear both: a view whose state is rebuilt (a re-created navigation
/// root, a scene the system restores) re-reads the gate, and clearing only
/// the presented flag brought the introduction back.
enum IntroductionGate {

    /// Pro networks and an unknown balance never see the introduction; every
    /// other network sees it until it is marked complete.
    static func shouldDisplay(
        introductionComplete: Bool,
        isPro: Bool,
        balanceUnavailable: Bool = false
    ) -> Bool {
        if isPro || balanceUnavailable {
            return false
        }
        return !introductionComplete
    }

    /// Marks the introduction finished in memory and persists it, so no
    /// rebuilt view or later launch shows it again. `persist` writes the SDK
    /// flag; it runs before the caller navigates away.
    static func finish(introductionComplete: Binding<Bool>, persist: () -> Void) {
        persist()
        if !introductionComplete.wrappedValue {
            introductionComplete.wrappedValue = true
        }
    }
}
