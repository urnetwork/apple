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
                // verified: a purchase entry continues to its checkout
                onConverted?()
            },
            // closed on the code step: the guest state lifts, but the user
            // left, so the purchase closes with the sheet
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
 *
 * The gate reads the server's guest status again as it opens (a balance
 * read), and follows it while it shows: a balance that reports a guest, or a
 * checkout the server refused as one (MainView's serverRefusedGuestPurchase),
 * swaps the checkout for the conversion. A refreshed guest reads as an
 * account until the balance answers, so the App Store checkout waits for that
 * answer, with a retry when the read fails (`purchaseEntry`).
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
        let guestModeClaim = deviceManager.parsedJwt?.guestMode
        let entry = GuestAccount.purchaseEntry(
            isGuest: GuestAccount.isGuest(
                guestModeClaim: guestModeClaim,
                serverGuest: subscriptionBalanceViewModel.isGuest
            ),
            guestKnown: GuestAccount.isGuestKnown(
                guestModeClaim: guestModeClaim,
                serverAnswered: subscriptionBalanceViewModel.isGuestKnown
            ),
            checkoutRefusesGuests: BillingDistribution.current.checkoutRefusesGuests,
            signInMethodAdded: signInMethodAdded
        )
        Group {
            switch entry {
            case .checkout:
                checkout()
            case .addSignInMethod:
                // under the conversion until it closes
                themeManager.currentTheme.backgroundColor.ignoresSafeArea()
            case .checkingGuest:
                guestCheck
            }
        }
        .onAppear {
            // the guest status from the network's live sign-in methods, not
            // whatever the last balance read said
            recheckGuest()
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
        .sheetOffTheFold(
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

    /// Reads the balance again, and with it the server's guest status.
    private func recheckGuest() {
        Task {
            await subscriptionBalanceViewModel.fetchSubscriptionBalance()
        }
    }

    /// Stands in for the checkout until the balance answers: a spinner while
    /// it loads, a retry when it failed. On macOS the close the checkout
    /// would carry is here too.
    private var guestCheck: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            HStack {
                Spacer()
                Button(action: {
                    dismiss()
                }) {
                    Image(systemName: "xmark")
                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                }
                .buttonStyle(.plain)
                .help(String(localized: "Close"))
            }
            #endif

            Spacer()

            if subscriptionBalanceViewModel.errorFetchingSubscriptionBalance && !subscriptionBalanceViewModel.isLoading {
                SectionLoadFailedView(retry: {
                    recheckGuest()
                })
            } else {
                ProgressView()
            }

            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 320)
        #endif
        .background(themeManager.currentTheme.backgroundColor.ignoresSafeArea())
    }
}
