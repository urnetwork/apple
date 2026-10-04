//
//  BittensorWalletSignView.swift
//  URnetwork
//
//  The screens of a BittensorWalletConnector: the wallet chooser (Talisman,
//  TAO.com), the manual form (the challenge to sign, the coldkey address and
//  the pasted signature) and the browser hand-off. Used by sign-in and by the
//  Earnings coldkey sheet.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct BittensorWalletSignView: View {

    @EnvironmentObject var themeManager: ThemeManager
    @ObservedObject var connector: BittensorWalletConnector
    /// a wallet was picked in the chooser
    let onChoose: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch connector.stage {

            case .idle, .choosing:
                Text("Choose your Bittensor wallet")
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(themeManager.currentTheme.textColor)
                ForEach(BittensorWallet.walletIds, id: \.self) { walletId in
                    UrButton(
                        text: LocalizedStringKey(BittensorWallet.displayName(walletId)),
                        action: {
                            onChoose(walletId)
                        },
                        style: .secondary,
                        accessibilityIdentifier: "bittensor.wallet.\(walletId)"
                    )
                }
                cancelButton

            case .requestingChallenge:
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Connecting to wallet...")
                        .font(themeManager.currentTheme.secondaryBodyFont)
                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                }
                cancelButton

            case .awaitingBrowser(let walletId):
                HStack(alignment: .top, spacing: 12) {
                    ProgressView()
                    Text("Continue in your browser and approve the request in the \(BittensorWallet.displayName(walletId)) extension.")
                        .font(themeManager.currentTheme.secondaryBodyFont)
                        .foregroundColor(themeManager.currentTheme.textColor)
                }
                cancelButton

            case .manualSignature(let walletId, let message):
                manualForm(walletId: walletId, message: message)

            case .failed(let errorText):
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(themeManager.currentTheme.dangerColor)
                    Text(verbatim: errorText)
                        .font(themeManager.currentTheme.secondaryBodyFont)
                        .foregroundColor(themeManager.currentTheme.textColor)
                }
                UrButton(text: "Retry", action: {
                    connector.presentChooser()
                })
                cancelButton
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func manualForm(walletId: String, message: String) -> some View {
        Text("Sign this message with the \(BittensorWallet.displayName(walletId)) wallet that holds your coldkey, then paste the address and the signature below.")
            .font(themeManager.currentTheme.secondaryBodyFont)
            .foregroundColor(themeManager.currentTheme.textColor)
            .fixedSize(horizontal: false, vertical: true)

        Text("Message to sign")
            .font(themeManager.currentTheme.secondaryBodyFont)
            .foregroundColor(themeManager.currentTheme.textMutedColor)
        Text(verbatim: message)
            .font(.system(.footnote, design: .monospaced))
            .foregroundColor(themeManager.currentTheme.textColor)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        Button(action: {
            copyToPasteboard(message)
        }) {
            Label("Copy", systemImage: "doc.on.doc")
                .font(themeManager.currentTheme.secondaryBodyFont)
        }
        .buttonStyle(.plain)
        .foregroundColor(themeManager.currentTheme.textMutedColor)

        TextField("", text: $connector.manualAddress, prompt: Text("Enter a Bittensor address"))
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
            .autocorrectionDisabled()
            .disabled(connector.addressLocked)
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif

        Text("Signature")
            .font(themeManager.currentTheme.secondaryBodyFont)
            .foregroundColor(themeManager.currentTheme.textMutedColor)
        TextField("", text: $connector.manualSignature, prompt: Text("Paste the 0x… signature"))
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif

        if let manualError = connector.manualError {
            Text(verbatim: manualError)
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(themeManager.currentTheme.dangerColor)
        }

        UrButton(
            text: "Continue",
            action: {
                Task {
                    await connector.submitManual()
                }
            },
            enabled: !connector.manualAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !connector.manualSignature.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
        cancelButton
    }

    private var cancelButton: some View {
        Button(action: {
            connector.cancel()
            onCancel()
        }) {
            Text("Cancel")
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(themeManager.currentTheme.textMutedColor)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    private func copyToPasteboard(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}
