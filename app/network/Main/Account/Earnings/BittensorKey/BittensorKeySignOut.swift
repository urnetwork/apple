//
//  BittensorKeySignOut.swift
//  URnetwork
//
//  The confirmation a sign out gets while the network's payout key isn't saved
//  (apple/BTEASY.md, Edge cases). The key survives the sign out, keyed by network
//  id, and comes back when that network signs in again, but a phone lost in
//  between takes the only copy with it. With no such key a sign out asks nothing,
//  as it always did.
//

import SwiftUI

@MainActor
final class BittensorKeySignOut: ObservableObject {

    static let shared = BittensorKeySignOut()

    /// the sign out waiting for the user's answer
    @Published private(set) var pending: (() -> Void)?

    private let needsBackup: (String?) -> Bool

    init(needsBackup: @escaping (String?) -> Bool = { BittensorLocalKeyStore.shared.needsBackup(networkId: $0) }) {
        self.needsBackup = needsBackup
    }

    /// Runs `signOut` now, or after the user confirms it.
    func request(networkId: String?, signOut: @escaping () -> Void) {
        if needsBackup(networkId) {
            pending = signOut
        } else {
            signOut()
        }
    }

    func confirm() {
        let signOut = pending
        pending = nil
        signOut?()
    }

    func cancel() {
        pending = nil
    }

    static let warning = String(localized: "Your Bittensor recovery phrase isn't saved yet. The key stays on this device and comes back when this network signs in again. If you lose this device before saving it, your SN25α can't be reached.")
}

/// The confirmation, once at the root of each window (the mocks' 3f): Back up
/// first opens the Key screen instead of signing out.
struct BittensorKeySignOutAlert: ViewModifier {

    @ObservedObject var signOut: BittensorKeySignOut = .shared
    @EnvironmentObject var deepLinkRouter: DeepLinkRouter

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Your Bittensor key isn't backed up",
            isPresented: Binding(
                get: { signOut.pending != nil },
                set: { presented in
                    if !presented {
                        signOut.cancel()
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("Back up first") {
                signOut.cancel()
                deepLinkRouter.openEarningsKeyScreen()
            }
            .accessibilityIdentifier("acceptance.account.logout.backUpFirst")
            Button("Sign out", role: .destructive) {
                signOut.confirm()
            }
            .accessibilityIdentifier("acceptance.account.logout.keyWarning")
            Button("Cancel", role: .cancel) {
                signOut.cancel()
            }
        } message: {
            Text("It stays on this device and comes back when you sign in to this network again. If you lose this device before saving it, your SN25α can't be reached.")
        }
    }
}
