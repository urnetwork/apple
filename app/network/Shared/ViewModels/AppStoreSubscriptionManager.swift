//
//  SubscriptionManager.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2024/12/31.
//

import Combine
import Foundation
import StoreKit
import URnetworkSdk

/**
 * The outcome of a restore-purchases pass, so the caller knows whether to
 * start the confirmation poll (`.restored` only — a purchase made under a
 * DIFFERENT network must not spin this network's poll).
 */
enum RestorePurchasesOutcome {
    case restored
    case restoredOtherNetwork
    case nothingToRestore
    case failed
}

/**
 * For creating a subscription with the App Store
 */
@MainActor
class AppStoreSubscriptionManager: ObservableObject {
    // @Published var products: [Product] = []

    @Published var monthlySubscription: Product?
    @Published var yearlySubscription: Product?

    @Published var isPurchasing: Bool = false
    @Published private(set) var purchaseSuccess: Bool = false

    /**
     * StoreKit ACCEPTED the purchase but it is not complete: it needs approval
     * (Ask to Buy) or another auth step (SCA). No transaction arrives now -- it lands
     * later on `Transaction.updates`.
     *
     * This used to be swallowed: `case .pending` only printed, so the sheet's spinner
     * simply stopped and dropped the user back on the product list with no
     * explanation. They reasonably conclude the purchase failed -- and try to buy
     * again.
     */
    @Published private(set) var purchasePending: Bool = false

    /**
     * A user-facing, localized description of why the purchase attempt failed.
     *
     * Every failure path used to end in `print` -- a thrown StoreKit error, an
     * unverified transaction, even a nil/unparseable networkId (which silently
     * returned before the App Store was ever contacted). The user tapped "buy",
     * the spinner stopped, and nothing explained what happened. The upgrade
     * surfaces render this inline. nil while there is no error. User
     * cancellation is deliberately NOT an error.
     */
    @Published private(set) var purchaseError: String?

    /**
     * The product fetch at init failed (or returned no products). Without this
     * flag the upgrade sheet showed an eternal spinner: `fetchProducts` ran
     * once at init and was never retried. The sheet retries on open via
     * `retryFetchProductsIfNeeded` and shows a retry affordance when this is
     * set.
     */
    @Published private(set) var fetchProductsError: Bool = false

    /**
     * A restore pass is running (`AppStore.sync()` can prompt for App Store
     * credentials, so this can be slow).
     */
    @Published private(set) var isRestoringPurchases: Bool = false

    /**
     * Localized outcome of the last restore pass, for inline display or a
     * snackbar. Cleared with the rest of the per-attempt state.
     */
    @Published private(set) var restoreResultMessage: String?

    private var networkId: SdkId?
    var onPurchaseSuccess: (() -> Void)?

    /**
     * Bumped for every transaction the process-scoped
     * `AppStoreTransactionMonitor` delivers FOR THIS NETWORK — an Ask to Buy
     * approval that came through later, a purchase made on another device, a
     * renewal, anything that completed while the app was closed or logged out.
     *
     * The monitor listens from process launch; this manager only exists after
     * login. The subscription below replays the monitor's current state at
     * init, so a transaction that arrived while the login screen was up is
     * picked up the moment its network logs in (see the onAppear catch-up in
     * `MainView`). Transactions whose appAccountToken does not match this
     * manager's networkId are ignored: they belong to a different network and
     * must not start this network's confirmation poll.
     */
    @Published private(set) var transactionUpdateSequence: Int = 0

    private var isFetchingProducts = false
    private var monitorCancellable: AnyCancellable?
    private let transactionMonitor: AppStoreTransactionMonitor

    init(networkId: SdkId?, transactionMonitor: AppStoreTransactionMonitor = .shared) {
        self.networkId = networkId
        self.transactionMonitor = transactionMonitor

        // Note this sink fires immediately with the monitor's current value
        // (catch-up for transactions delivered before login), then again for
        // every new transaction.
        monitorCancellable = transactionMonitor.$transactionSequence
            .sink { [weak self] sequence in
                guard let self, 0 < sequence else {
                    return
                }
                // per-network gating: only a transaction purchased under THIS
                // network (appAccountToken == networkId) may start its
                // confirmation poll
                guard
                    let token = transactionMonitor.lastTransactionAppAccountToken,
                    let networkId = self.networkId,
                    let networkUUID = UUID(uuidString: networkId.idStr),
                    token == networkUUID
                else {
                    return
                }
                // The in-flight purchase callback, when there IS one.
                self.onPurchaseSuccess?()
                // ...and the signal that always fires (the callback is only
                // assigned inside purchase(), so it is nil on a fresh launch).
                self.transactionUpdateSequence += 1
            }

        /**
         * This manager only exists once a session does (it is created with
         * MainView, post-login), so this is the "a session now exists" signal
         * the report-then-finish sequence waits on: anything whose report was
         * deferred while logged out (or that ran out of in-session retries)
         * gets re-reported now.
         */
        transactionMonitor.retryDeferredReports()

        Task {
            await fetchProducts()
        }
    }

    func fetchProducts() async {
        guard !isFetchingProducts else {
            return
        }
        isFetchingProducts = true
        defer { isFetchingProducts = false }

        do {
            let productIdentifiers = ["supporter_monthly_26", "supporter_yearly_26"]

            let storeProducts = try await Product.products(for: productIdentifiers)

            if let monthlySub = storeProducts.first(where: { $0.id == "supporter_monthly_26" }) {
                self.monthlySubscription = monthlySub
            }

            if let yearlySub = storeProducts.first(where: { $0.id == "supporter_yearly_26" }) {
                self.yearlySubscription = yearlySub
            }

            print("Retrieved products: \(storeProducts.count)")

            // an empty result is a failure for the UI's purposes: there is
            // nothing to render and nothing to buy
            self.fetchProductsError = (monthlySubscription == nil || yearlySubscription == nil)
        } catch {
            print("Failed to fetch products: \(error)")
            self.fetchProductsError = true
        }
    }

    /**
     * Retry the product fetch if it never succeeded. Called when an upgrade
     * surface appears: the init-time fetch used to be the only attempt, so a
     * transient network failure at launch left the sheet spinning forever.
     */
    func retryFetchProductsIfNeeded() {
        guard monthlySubscription == nil || yearlySubscription == nil else {
            return
        }
        Task {
            await fetchProducts()
        }
    }

    @MainActor
    private func setIsPurchasing(_ isPurchasing: Bool) async {
        self.isPurchasing = isPurchasing
    }

    /**
     * VPN + purchase (finding A6):
     *
     * The macOS call sites disconnect the tunnel around this call ("purchase
     * fails in mac app store if vpn is connected") and reconnect after. iOS
     * deliberately does NOT copy that:
     *
     * - The iOS App Store purchase path runs out of process, in Apple's system
     *   daemons (`appstored`/`itunesstored`) and the StoreKit system UI, not in
     *   the app.
     * - The tunnel (extension `PacketTunnelProvider` + `VPNManager`) does not
     *   set `includeAllNetworks`; it installs a default IPv4 route with only
     *   RFC1918 excluded, and sets `excludeCellularServices`, `excludeAPNs`,
     *   and (17.4+) `excludeDeviceCommunication`. Without `includeAllNetworks`,
     *   iOS routes Apple system-service traffic — including App Store
     *   purchases — outside NEPacketTunnelProvider tunnels. (This is the
     *   OS behavior privacy researchers report as the "iOS VPN leak" of Apple
     *   services; here it is what makes purchasing safe while connected.)
     * - Empirically the failure was only ever observed on the Mac App Store,
     *   where the store client does honor the tunnel's default route.
     *
     * So an iOS purchase does not ride the tunnel, and disconnecting the VPN
     * here would be gratuitous churn for the buyer most likely to be
     * connected. If Apple ever changes the exclusion, the failure is no longer
     * silent: purchase errors surface via `purchaseError`, and "Restore
     * purchases" recovers a purchase that completed but was not observed.
     */
    func purchase(product: Product, onSuccess: @escaping (() -> Void)) async throws {
        guard !isPurchasing else { return }

        await setIsPurchasing(true)

        /**
         * A new attempt starts clean.
         *
         * Without this, `purchaseSuccess` from an EARLIER attempt survives: the
         * manager is a @StateObject on MainView, so it lives for the whole session and
         * nothing ever set the flag back to false. Reopening the upgrade sheet then
         * renders PurchaseSuccessView immediately -- "You're premium." -- to a user
         * whose purchase never actually completed.
         */
        setPurchaseSuccess(false)
        setPurchasePending(false)
        self.purchaseError = nil
        self.restoreResultMessage = nil

        self.onPurchaseSuccess = onSuccess

        do {
            var purchaseOptions: Set<Product.PurchaseOption> = []

            /**
             * The purchase is attributed to the network via appAccountToken.
             * With no usable networkId the App Store webhook could never
             * credit anyone -- refuse loudly instead of the old silent return
             * (the user tapped "buy" and nothing at all happened).
             */
            guard let networkId = self.networkId, let networkUUID = UUID(uuidString: networkId.idStr) else {
                self.purchaseError = String(localized: "Your account isn't ready for purchases. Please restart the app and try again.")
                await setIsPurchasing(false)
                return
            }

            purchaseOptions.insert(.appAccountToken(networkUUID))

            let result = try await product.purchase(options: purchaseOptions)

            switch result {
            case .success(let verification):
                switch verification {
                case .verified(let transaction):
                    print("✅ Purchase verified: \(transaction.id)")

                    logTransactionDetails(transaction)

                    /**
                     * Report-then-finish (finding A1): the transaction JWS is
                     * persisted and reported to the server, and finish() only
                     * happens after a terminal answer — through the SAME
                     * sequence the process-scoped monitor runs for every other
                     * delivery path. Finishing here without server contact is
                     * what made a lost webhook a permanent dead end: a
                     * finished transaction is never redelivered.
                     */
                    let outcome = await transactionMonitor.process(
                        transaction: transaction,
                        jws: verification.jwsRepresentation
                    )

                    switch outcome {
                    case .credited:
                        /**
                         * The server acknowledged the credit. The monitor
                         * bumped its sequence, and the sink in init already
                         * invoked `onPurchaseSuccess` (which starts the
                         * confirmation poll) — don't double-start it here.
                         *
                         * NOTE: this flag still only shapes the sheet; the
                         * success screens key their copy off the poll's
                         * outcome, and the poll closes the loop by refreshing
                         * the jwt to pro.
                         */
                        setPurchaseSuccess(true)

                    case .wrongNetwork:
                        /**
                         * Real purchase, different network (the session
                         * changed under the flow). It was finished — the
                         * linked network is credited via webhook/reconciler —
                         * but this network must not show success or poll.
                         */
                        self.purchaseError = String(localized: "Your subscription was purchased under a different account. Log in to that account to use it.")

                    case .invalid:
                        /**
                         * The server says this proof will never verify. The
                         * transaction was finished so StoreKit stops
                         * redelivering it; tell the user with a recourse
                         * instead of a silent success.
                         */
                        self.purchaseError = String(localized: "This purchase couldn't be verified with the App Store, so it can't be applied to your account. If you were charged and your plan doesn't update, please contact support.")

                    case .deferredNoSession, .transientFailure, .alreadyInFlight:
                        /**
                         * The server couldn't be reached (or answered
                         * non-terminally): the JWS is persisted, the
                         * transaction stays UNFINISHED, and StoreKit will
                         * redeliver it — the report retries at next launch /
                         * login / restore. Meanwhile the webhook may still
                         * credit the purchase, so start the confirmation poll
                         * (no monitor bump happened, so start it directly) and
                         * show the poll-keyed confirming screen.
                         */
                        self.onPurchaseSuccess?()
                        setPurchaseSuccess(true)
                    }

                case .unverified( _, let error):
                    print("Purchase unverified: \(error)")
                    throw error
                }

            case .userCancelled:
                print("Purchase cancelled by user")
                throw SKError(.paymentCancelled)

            case .pending:
                /**
                 * Ask to Buy (a child needing a parent's approval) or an SCA step. The
                 * purchase is NOT done and no transaction arrives now -- it lands later
                 * on Transaction.updates. Surface it, so the sheet can tell the user
                 * their purchase is awaiting approval instead of silently returning
                 * them to the product list as if nothing happened.
                 */
                print("Purchase pending approval")
                setPurchasePending(true)

            @unknown default:
                print("Unknown purchase result")
            }
        } catch {
            print("Purchase failed: \(error)")
            if !Self.isUserCancellation(error) {
                self.purchaseError = String(localized: "The purchase could not be completed. Please try again.")
            }
            await setIsPurchasing(false)
            throw error
        }

        await setIsPurchasing(false)
    }

    /**
     * The user backing out of the payment sheet is not an error and must not
     * render as one.
     */
    private static func isUserCancellation(_ error: Error) -> Bool {
        if let skError = error as? SKError, skError.code == .paymentCancelled {
            return true
        }
        if let storeKitError = error as? StoreKitError, case .userCancelled = storeKitError {
            return true
        }
        return false
    }

    /**
     * Restore purchases (finding A3): the only user-triggerable resync.
     *
     * Sync with the App Store, finish anything unfinished (an unfinished
     * transaction is redelivered forever but was previously only consumed by a
     * listener that might not be running), and scan current entitlements. An
     * entitlement purchased under THIS network reports `.restored` — the
     * caller starts the confirmation poll so the server-side credit (via
     * webhook) is picked up. An entitlement under a different network is
     * reported as such, not silently dropped.
     */
    func restorePurchases() async -> RestorePurchasesOutcome {
        guard !isRestoringPurchases else {
            return .failed
        }
        isRestoringPurchases = true
        restoreResultMessage = nil
        defer { isRestoringPurchases = false }

        // AppStore.sync() forces a refresh of signed transactions from the
        // App Store; it throws if the user cancels the credentials prompt.
        // Local entitlements are still worth scanning either way.
        var syncFailed = false
        do {
            try await AppStore.sync()
        } catch {
            print("[restorePurchases] AppStore.sync failed: \(error)")
            syncFailed = true
        }

        /**
         * Unfinished transactions are exactly the ones whose report never
         * reached a terminal status (the monitor no longer finishes anything
         * the server hasn't acknowledged). Route them through the same
         * report-then-finish sequence rather than finishing blind — a restore
         * pass with the network back is often what completes a report that
         * failed at purchase time. Credited outcomes bump the monitor
         * sequence, which starts the confirmation poll via the per-network
         * gate.
         */
        for await result in Transaction.unfinished {
            if case .verified(let transaction) = result {
                _ = await transactionMonitor.process(
                    transaction: transaction,
                    jws: result.jwsRepresentation
                )
            }
        }

        let currentNetworkUUID: UUID? = networkId.flatMap { UUID(uuidString: $0.idStr) }

        var foundCurrent = false
        var foundOther = false
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result, transaction.revocationDate == nil else {
                continue
            }
            if let token = transaction.appAccountToken, let currentNetworkUUID, token == currentNetworkUUID {
                foundCurrent = true
            } else {
                foundOther = true
            }
        }

        if foundCurrent {
            restoreResultMessage = String(localized: "Purchase found. Confirming your plan — it will update automatically.")
            return .restored
        }
        if foundOther {
            restoreResultMessage = String(localized: "Your subscription was purchased under a different account. Log in to that account to use it.")
            return .restoredOtherNetwork
        }
        if syncFailed {
            restoreResultMessage = String(localized: "Couldn't restore purchases. Please try again.")
            return .failed
        }
        restoreResultMessage = String(localized: "No previous purchases were found.")
        return .nothingToRestore
    }

    @MainActor
    func setPurchaseSuccess(_ success: Bool) {
        self.purchaseSuccess = success
    }

    @MainActor
    func setPurchasePending(_ pending: Bool) {
        self.purchasePending = pending
    }

    /**
     * Clear the terminal states so the upgrade sheet opens fresh. Called when the
     * sheet is dismissed: the flags describe ONE attempt, and letting them leak into
     * the next presentation is what showed "You're premium." to a user who was not.
     */
    @MainActor
    func resetPurchaseState() {
        self.purchaseSuccess = false
        self.purchasePending = false
        self.purchaseError = nil
        self.restoreResultMessage = nil
    }

    private func logTransactionDetails(_ transaction: Transaction) {
        print("Transaction ID: \(transaction.id)")
        print("Product ID: \(transaction.productID)")
        print("Purchase Date: \(transaction.purchaseDate)")

        if let appAccountToken = transaction.appAccountToken {
            print("App Account Token: \(appAccountToken)")
        }
    }
}
