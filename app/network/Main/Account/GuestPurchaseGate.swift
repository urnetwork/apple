//
//  GuestPurchaseGate.swift
//  URnetwork
//

import SwiftUI

/**
 * The in-place conversion of a legacy guest (see GuestAccount): the
 * add-sign-in-method sheet on the current network, then the jwt is re-signed
 * and the balance refetched. It never signs in to another network.
 */
struct GuestConversionSheet: View {

    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var deviceManager: DeviceManager
    @EnvironmentObject var snackbarManager: UrSnackbarManager
    @EnvironmentObject var subscriptionBalanceViewModel: SubscriptionBalanceViewModel
    @EnvironmentObject var connectWalletProviderViewModel: ConnectWalletProviderViewModel

    let urApiService: UrApiServiceProtocol

    var body: some View {
        // The jwt re-sign and balance refetch wait for the code: refetching the
        // balance as soon as AddAuth succeeds clears the server's `guest`, which
        // swaps this sheet for the checkout in the middle of the code step.
        // Closing on the code step still lifts the guest state: the network has
        // a sign-in method now, verified at its first sign-in.
        AddAuthSheet(
            api: urApiService,
            networkUserViewModel: nil,
            onAdded: {
                signInMethodAdded()
            },
            onClosedUnverified: {
                signInMethodAdded()
            }
        )
        .environmentObject(themeManager)
        .environmentObject(deviceManager)
        .environmentObject(snackbarManager)
        .environmentObject(connectWalletProviderViewModel)
    }

    private func signInMethodAdded() {
        GuestAccountConversion(
            session: DeviceGuestAccountSession(
                deviceManager: deviceManager,
                subscriptionBalanceViewModel: subscriptionBalanceViewModel
            )
        ).signInMethodAdded()
    }
}

/**
 * Wraps a purchase entry (upgrade sheet, welcome offer): a legacy guest gets
 * the in-place conversion instead of the checkout, until its network has a
 * sign-in method. A plan bought on a guest network is stranded there, since
 * nothing can sign back in to it.
 */
struct GuestPurchaseGate<Checkout: View>: View {

    @EnvironmentObject var deviceManager: DeviceManager
    @EnvironmentObject var subscriptionBalanceViewModel: SubscriptionBalanceViewModel

    let urApiService: UrApiServiceProtocol
    @ViewBuilder let checkout: () -> Checkout

    var body: some View {
        let isGuest = GuestAccount.isGuest(
            guestModeClaim: deviceManager.parsedJwt?.guestMode,
            serverGuest: subscriptionBalanceViewModel.isGuest
        )
        switch GuestAccount.purchaseEntry(isGuest: isGuest) {
        case .checkout:
            checkout()
        case .addSignInMethod:
            GuestConversionSheet(urApiService: urApiService)
        }
    }
}
