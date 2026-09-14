//
//  ConnectSolanaWalletSheet.swift
//  URnetwork
//
//  The sheet that links the Solana wallet USDC payouts go to: hand off to
//  Phantom or Solflare (the apps on iOS, their browser extensions through the
//  ur.io bridge on macOS), or enter the address manually. Shows the address
//  check, the wait for the wallet and the errors.
//

import SwiftUI

struct ConnectSolanaWalletSheet: View {

    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var connectWalletProviderViewModel: ConnectWalletProviderViewModel
    @EnvironmentObject var snackbarManager: UrSnackbarManager
    @ObservedObject var flow: ConnectSolanaWalletFlow
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Connect Solana wallet")
                    .font(themeManager.currentTheme.toolbarTitleFont)
                    .foregroundColor(themeManager.currentTheme.textColor)
                Spacer()
                #if os(macOS)
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                }
                .keyboardShortcut(.cancelAction)
                #endif
            }
            content
            Spacer(minLength: 0)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(themeManager.currentTheme.backgroundColor)
    }

    @ViewBuilder
    private var content: some View {
        switch flow.stage {

        case .chooser:
            Text("Connect a Solana wallet app, or enter a Solana USDC address manually.")
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(themeManager.currentTheme.textMutedColor)
            Text("USDC payouts continue to this wallet until the migration to Bittensor is complete.")
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(themeManager.currentTheme.textMutedColor)
            HStack(spacing: 12) {
                SolanaWalletAppTile(app: .phantom, isEnabled: isPhantomInstalled, action: {
                    open(.phantom)
                })
                SolanaWalletAppTile(app: .solflare, isEnabled: isSolflareInstalled, action: {
                    open(.solflare)
                })
            }
            if !isPhantomInstalled && !isSolflareInstalled {
                Text("Please install Phantom or Solflare to use this feature")
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(themeManager.currentTheme.textColor)
            }
            Button(action: {
                flow.enterManually()
            }) {
                Text("Enter address manually")
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(themeManager.currentTheme.textMutedColor)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("acceptance.solana.manual")

        case .awaitingWallet(let app):
            connectingLine
            UrButton(
                text: "Retry",
                action: {
                    open(app)
                },
                style: .secondary
            )
            cancelButton

        case .manualEntry:
            addressField
            UrButton(
                text: "Connect",
                action: submit,
                enabled: flow.manualValidation == .valid,
                accessibilityIdentifier: "acceptance.solana.connect"
            )
            cancelButton

        case .connecting:
            connectingLine

        case .failed(let message):
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(themeManager.currentTheme.dangerColor)
                Text(verbatim: message)
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(themeManager.currentTheme.textColor)
            }
            UrButton(text: "Retry", action: {
                Task {
                    await flow.retry()
                }
            })
            cancelButton
        }
    }

    @ViewBuilder
    private var addressField: some View {
        #if os(iOS)
        UrTextField(
            text: $flow.manualAddress,
            label: "USDC wallet address",
            placeholder: "Enter a Solana USDC wallet address",
            supportingText: supportingText,
            validationState: fieldValidationState,
            keyboardType: .asciiCapable,
            submitLabel: .go,
            onSubmit: submit,
            disableCapitalization: true,
            accessibilityIdentifier: "acceptance.solana.address",
            disableAutocorrection: true
        )
        #else
        UrTextField(
            text: $flow.manualAddress,
            label: "USDC wallet address",
            placeholder: "Enter a Solana USDC wallet address",
            supportingText: supportingText,
            validationState: fieldValidationState,
            submitLabel: .go,
            onSubmit: submit,
            disableCapitalization: true,
            accessibilityIdentifier: "acceptance.solana.address"
        )
        #endif
    }

    /// the flow's text is already localized
    private var supportingText: LocalizedStringKey? {
        flow.manualSupportingText.map { LocalizedStringKey($0) }
    }

    /// A check that failed reads as an error in the field, while the flow keeps
    /// the address unchecked for the Connect button.
    private var fieldValidationState: ValidationState {
        if flow.manualValidation == .notChecked && flow.manualSupportingText != nil {
            return .invalid
        }
        return flow.manualValidation
    }

    private var connectingLine: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text("Connecting to wallet...")
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(themeManager.currentTheme.textMutedColor)
        }
    }

    private var cancelButton: some View {
        Button(action: {
            flow.reset()
        }) {
            Text("Cancel")
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(themeManager.currentTheme.textMutedColor)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    private var isPhantomInstalled: Bool {
        connectWalletProviderViewModel.isWalletAppInstalled(.phantom)
    }

    private var isSolflareInstalled: Bool {
        connectWalletProviderViewModel.isWalletAppInstalled(.solflare)
    }

    private func open(_ app: ConnectSolanaWalletFlow.WalletApp) {
        if !flow.start(app) {
            showWalletOpenFailed()
        }
    }

    private func submit() {
        Task {
            await flow.submitManualAddress()
        }
    }

    private func showWalletOpenFailed() {
        snackbarManager.showSnackbar(message: String(localized: "Couldn't open wallet. Please install it and try again."))
    }
}

/// A wallet app: its logo on the wallet's color above its name. On iOS the
/// tile is disabled when the app is not installed.
private struct SolanaWalletAppTile: View {

    @EnvironmentObject var themeManager: ThemeManager

    let app: ConnectSolanaWalletFlow.WalletApp
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack {
                logo
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 36, height: 36)
                    .padding()
                    .background(background)
                    .cornerRadius(12)
                    .accessibilityHidden(true)

                Text(name)
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(themeManager.currentTheme.textColor)
            }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private var logo: Image {
        switch app {
        case .phantom:
            return Image("phantom.white.logo")
        case .solflare:
            return Image("solflare.logo")
        }
    }

    private var background: Color {
        switch app {
        case .phantom:
            return Color(hex: "#ab9ff2")
        case .solflare:
            return .urWhite
        }
    }

    private var name: LocalizedStringKey {
        switch app {
        case .phantom:
            return "Phantom"
        case .solflare:
            return "Solflare"
        }
    }

    private var accessibilityIdentifier: String {
        switch app {
        case .phantom:
            return "acceptance.solana.phantom"
        case .solflare:
            return "acceptance.solana.solflare"
        }
    }
}

#Preview {
    let themeManager = ThemeManager.shared
    ConnectSolanaWalletSheet(
        flow: ConnectSolanaWalletFlow(client: UsdcWalletsPreviewClient()),
        dismiss: {}
    )
    .environmentObject(themeManager)
    .environmentObject(ConnectWalletProviderViewModel())
    .environmentObject(UrSnackbarManager())
}
