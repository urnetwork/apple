//
//  ConnectionAwareSubscriptionStore.swift
//  URnetwork
//
//  The store every upgrade surface sells through (makeSubscriptionStore): the
//  build's store, with ConnectViewModel.purchaseAroundConnection around its
//  purchases. It sits here rather than at the surfaces so a new surface cannot
//  buy past it: makeSubscriptionStore takes the connection, and everything
//  else is forwarded as it is.
//
//  The notice before the disconnect is an AppKit alert for the same reason. A
//  SwiftUI alert has to hang from a view on the sheet each surface shows, and a
//  surface without one would wait on it forever. The alert asks from here,
//  over whatever is on screen, and always answers.
//

import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#endif

@MainActor
final class ConnectionAwareSubscriptionStore: SubscriptionStore {

    private let store: any SubscriptionStore
    private let connection: ConnectViewModel

    init(store: any SubscriptionStore, connection: ConnectViewModel) {
        self.store = store
        self.connection = connection
    }

    func purchase(plan: PaymentOption, onSuccess: @escaping () -> Void) async {
        let store = self.store
        await connection.purchaseAroundConnection {
            await store.purchase(plan: plan, onSuccess: onSuccess)
        }
    }

    func redeemOffer(_ offer: PlanOffer, onSuccess: @escaping () -> Void) async {
        let store = self.store
        await connection.purchaseAroundConnection {
            await store.redeemOffer(offer, onSuccess: onSuccess)
        }
    }

    var storeName: String { store.storeName }
    var distribution: BillingDistribution { store.distribution }

    func presentation(tier: PlanTier?, offer: PlanOffer?, storefrontCountryName: String?) -> PlanPresentation? {
        store.presentation(tier: tier, offer: offer, storefrontCountryName: storefrontCountryName)
    }

    var plansLoadFailed: Bool { store.plansLoadFailed }

    func retryLoadPlansIfNeeded(storefrontCountry: String?) {
        store.retryLoadPlansIfNeeded(storefrontCountry: storefrontCountry)
    }

    var isPurchasing: Bool { store.isPurchasing }
    var purchaseSuccess: Bool { store.purchaseSuccess }
    var purchasePending: Bool { store.purchasePending }
    var purchaseError: String? { store.purchaseError }
    var purchaseConfirmingTitle: String? { store.purchaseConfirmingTitle }
    var purchaseConfirmingMessage: String? { store.purchaseConfirmingMessage }
    var checkoutView: AnyView? { store.checkoutView }

    func resetPurchaseState() {
        store.resetPurchaseState()
    }

    func restorePurchases() async -> RestorePurchasesOutcome {
        await store.restorePurchases()
    }

    var isRestoringPurchases: Bool { store.isRestoringPurchases }
    var restoreResultMessage: String? { store.restoreResultMessage }
}

/// What the user is told before a purchase drops the connection. Its first
/// button goes ahead; only macOS ever drops one (purchaseDropsConnection).
@MainActor
enum PurchaseDisconnectNotice {

    static func confirm() async -> Bool {
        #if os(macOS)
        return await answer(makeAlert())
        #else
        return true
        #endif
    }

    #if os(macOS)
    /// Waits for a button in the alert's own modal loop. The loop starts from
    /// the run loop and not from this task: a run loop nested in a main queue
    /// block does not drain the main queue, so the main actor's other work (the
    /// status reports among it) would wait for the alert.
    static func answer(_ alert: NSAlert) async -> Bool {
        await withCheckedContinuation { continuation in
            RunLoop.main.perform(inModes: [.common]) {
                MainActor.assumeIsolated {
                    continuation.resume(returning: alert.runModal() == .alertFirstButtonReturn)
                }
            }
        }
    }

    static func makeAlert() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = String(localized: "Disconnect the VPN for this purchase?")
        alert.informativeText = String(localized: "URnetwork reconnects it afterward. Until it does, your internet traffic won't go through the VPN.")
        alert.addButton(withTitle: String(localized: "Disconnect"))
        // AppKit gives Escape to a button titled Cancel only in English
        alert.addButton(withTitle: String(localized: "Cancel")).keyEquivalent = "\u{1b}"
        return alert
    }
    #endif
}
