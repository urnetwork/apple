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
    /// Called once the sign-in method was added (after the jwt re-sign and
    /// balance refetch were started): a purchase entry continues to its checkout.
    var onConverted: (() -> Void)? = nil

    var body: some View {
        AddAuthSheet(
            api: urApiService,
            networkUserViewModel: nil,
            onAdded: {
                GuestAccountConversion(
                    session: DeviceGuestAccountSession(
                        deviceManager: deviceManager,
                        subscriptionBalanceViewModel: subscriptionBalanceViewModel
                    )
                ).signInMethodAdded()
                onConverted?()
            }
        )
        .environmentObject(themeManager)
        .environmentObject(deviceManager)
        .environmentObject(snackbarManager)
        .environmentObject(connectWalletProviderViewModel)
    }
}

/**
 * Wraps a purchase entry (upgrade sheet, welcome offer): a legacy guest gets
 * the in-place conversion instead of the checkout, until its network has a
 * sign-in method. A plan bought on a guest network is stranded there, since
 * nothing can sign back in to it.
 *
 * The conversion is presented over the gate, not as its content: the
 * add-sign-in sheet dismisses itself when it is done, and as the content it
 * closed the whole purchase sheet, so the user had to open the upgrade again.
 * Over the gate, its close lands on the checkout the user was opening once a
 * sign-in method was added (`purchaseEntry`), and closes the purchase sheet
 * when it was cancelled (`conversionClosed`).
 */
struct GuestPurchaseGate<Checkout: View>: View {

    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var deviceManager: DeviceManager
    @EnvironmentObject var snackbarManager: UrSnackbarManager
    @EnvironmentObject var subscriptionBalanceViewModel: SubscriptionBalanceViewModel
    @EnvironmentObject var connectWalletProviderViewModel: ConnectWalletProviderViewModel

    @Environment(\.dismiss) private var dismiss

    let urApiService: UrApiServiceProtocol
    @ViewBuilder let checkout: () -> Checkout

    /// set by the conversion: the network has a sign-in method now, before the
    /// re-signed jwt and the refetched balance say so
    @State private var signInMethodAdded = false
    @State private var isPresentedConversion = false

    var body: some View {
        let isGuest = GuestAccount.isGuest(
            guestModeClaim: deviceManager.parsedJwt?.guestMode,
            serverGuest: subscriptionBalanceViewModel.isGuest
        )
        let entry = GuestAccount.purchaseEntry(isGuest: isGuest, signInMethodAdded: signInMethodAdded)
        Group {
            switch entry {
            case .checkout:
                checkout()
            case .addSignInMethod:
                // under the conversion until it closes
                themeManager.currentTheme.backgroundColor.ignoresSafeArea()
            }
        }
        .onAppear {
            if entry == .addSignInMethod {
                isPresentedConversion = true
            }
        }
        .onChange(of: entry) { entry in
            // the balance can report a guest after the sheet opened
            if entry == .addSignInMethod {
                isPresentedConversion = true
            }
        }
        .sheet(
            isPresented: $isPresentedConversion,
            onDismiss: {
                if GuestAccount.conversionClosed(signInMethodAdded: signInMethodAdded) == .closePurchase {
                    dismiss()
                }
            }
        ) {
            GuestConversionSheet(
                urApiService: urApiService,
                onConverted: { signInMethodAdded = true }
            )
            .environmentObject(themeManager)
            .environmentObject(deviceManager)
            .environmentObject(snackbarManager)
            .environmentObject(subscriptionBalanceViewModel)
            .environmentObject(connectWalletProviderViewModel)
        }
    }
}
