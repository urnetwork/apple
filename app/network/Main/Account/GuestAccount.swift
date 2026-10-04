//
//  GuestAccount.swift
//  URnetwork
//

import Foundation

/**
 * Legacy guest networks (findings A4 and D8 in server/UPGRADE.md §3).
 *
 * The server no longer creates guest networks, but a network created as a
 * guest before July has no login method. Such a network can hold a plan and a
 * balance. "Create an account" used to run the login flow and sign in to a NEW
 * network, which left the paid plan and balance behind on the guest network
 * with no way back to it.
 *
 * A guest now converts in place: it adds a sign-in method to its own network
 * (the server's AddAuth), then re-signs the jwt and refetches the balance. The
 * network, its plan and its balance stay. Nothing logs out.
 *
 * Until a sign-in method exists, a guest is not sold a plan: every purchase
 * entry opens the conversion instead (see `purchaseEntry`).
 */
enum GuestAccount {

    /**
     * Whether the network is a legacy guest: the jwt's `guest_mode` claim, or
     * the server's subscription-balance `guest` (no login method).
     *
     * The claim alone misses most guests: every token refresh signs the jwt
     * without `guest_mode`, so a guest whose token was refreshed once read as a
     * normal account and could buy Pro for a network nothing can sign back in
     * to. The server reads `guest` from the live auth methods.
     *
     * No jwt is not a guest: a missing claim used to read as guest, which
     * offered the guest-only flows to a session that had not loaded yet.
     */
    static func isGuest(guestModeClaim: Bool?, serverGuest: Bool) -> Bool {
        (guestModeClaim ?? false) || serverGuest
    }

    enum PurchaseEntry: Equatable {
        /// the plans and the store checkout
        case checkout
        /// the in-place conversion: add a sign-in method to this network first
        case addSignInMethod
    }

    /**
     * Where a purchase entry (upgrade sheet, welcome offer, intro plan step)
     * leads. `signInMethodAdded`: the conversion opened from this entry added a
     * sign-in method, so the entry continues to its checkout without waiting for
     * the re-signed jwt and the refetched balance to stop reporting a guest.
     */
    static func purchaseEntry(isGuest: Bool, signInMethodAdded: Bool = false) -> PurchaseEntry {
        isGuest && !signInMethodAdded ? .addSignInMethod : .checkout
    }

    enum ConversionClose: Equatable {
        /// a sign-in method was added: stay on the purchase, now its checkout
        case continueToCheckout
        /// the conversion was cancelled: the guest is not sold a plan, so the
        /// purchase closes with it
        case closePurchase
    }

    /// What closing the conversion a purchase entry opened does to that entry.
    static func conversionClosed(signInMethodAdded: Bool) -> ConversionClose {
        signInMethodAdded ? .continueToCheckout : .closePurchase
    }
}

/**
 * The session a conversion runs on. `logout` is here so the contract is
 * explicit: the conversion never logs out (that is what stranded the balance).
 */
@MainActor
protocol GuestAccountSession: AnyObject {
    func refreshJwt()
    func refreshBalance()
    func logout()
}

/**
 * Completes the in-place conversion once a sign-in method was added to the
 * guest's own network.
 */
@MainActor
struct GuestAccountConversion {

    let session: GuestAccountSession

    /**
     * Re-sign the jwt so `guest_mode` clears (the refresh signs a non-guest
     * jwt for the same network), and refetch the balance so the server's
     * `guest` clears. The session stays on this network.
     */
    func signInMethodAdded() {
        session.refreshJwt()
        session.refreshBalance()
    }
}

/// The app's session: the device re-signs the jwt for the same network.
@MainActor
final class DeviceGuestAccountSession: GuestAccountSession {

    private weak var deviceManager: DeviceManager?
    private weak var subscriptionBalanceViewModel: SubscriptionBalanceViewModel?

    init(
        deviceManager: DeviceManager,
        subscriptionBalanceViewModel: SubscriptionBalanceViewModel?
    ) {
        self.deviceManager = deviceManager
        self.subscriptionBalanceViewModel = subscriptionBalanceViewModel
    }

    func refreshJwt() {
        do {
            try deviceManager?.device?.refreshToken(0)
        } catch {
            print("[GuestAccount] error refreshing the jwt: \(error)")
        }
    }

    func refreshBalance() {
        guard let subscriptionBalanceViewModel else { return }
        Task {
            await subscriptionBalanceViewModel.fetchSubscriptionBalance()
        }
    }

    func logout() {
        deviceManager?.logout()
    }
}
