//
//  NetworkConsentSheet.swift
//  URnetwork
//
//  The sheet that signs the network payout consent: choose the wallet, enter
//  the coldkey address the consent names, then sign the server's message in
//  the wallet (the browser bridge, or the manual form) while the sheet waits
//  for the signature. Shows the consent's own refusals (expired, signature
//  mismatch, not the network owner) and any other error.
//

import SwiftUI
import URnetworkSdk

struct NetworkConsentSheet: View {

    @EnvironmentObject var themeManager: ThemeManager
    @ObservedObject var flow: NetworkConsentFlow
    /// the flow's connector, observed for the wallet's progress
    @ObservedObject var connector: BittensorWalletConnector
    let dismiss: () -> Void

    var body: some View {
        // the manual form shows the whole message, about 2 KB of JSON, with
        // the signature field and Continue below it
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Payout consent")
                        .font(themeManager.currentTheme.toolbarTitleFont)
                        .foregroundColor(themeManager.currentTheme.textColor)
                    Spacer()
                }
                content
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(themeManager.currentTheme.backgroundColor)
    }

    @ViewBuilder
    private var content: some View {
        switch flow.stage {

        case .chooser:
            Text("Sign once with your Bittensor wallet so this network's earnings are paid to it.")
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(themeManager.currentTheme.textColor)
                .fixedSize(horizontal: false, vertical: true)
            BittensorWalletSignView(
                connector: connector,
                onChoose: { walletId in
                    flow.chooseWallet(walletId)
                },
                onCancel: dismiss
            )

        case .addressEntry:
            TextField("", text: $flow.address, prompt: Text("Enter a Bittensor address"))
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            if let addressError = flow.addressError {
                Text(verbatim: addressError)
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(themeManager.currentTheme.dangerColor)
            }
            UrButton(
                text: "Continue",
                action: {
                    Task {
                        await flow.submitAddress()
                    }
                },
                enabled: !flow.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
            cancelButton

        case .requestingChallenge:
            waiting
            cancelButton

        case .signing:
            if flow.awaitingSignature {
                waiting
            }
            BittensorWalletSignView(
                connector: connector,
                onChoose: { walletId in
                    flow.chooseWallet(walletId)
                },
                onCancel: {
                    flow.reset()
                }
            )

        case .submitting:
            ProgressView()

        case .failed(let failure):
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(themeManager.currentTheme.dangerColor)
                Text(verbatim: failure.text)
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(themeManager.currentTheme.textColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if failure == .ownerOnly {
                // another session cannot become the owner by retrying
                UrButton(text: "Close", action: dismiss)
            } else {
                // a new challenge for the same wallet and coldkey
                UrButton(text: "Retry", action: {
                    Task {
                        await flow.submitAddress()
                    }
                })
                cancelButton
            }
        }
    }

    private var waiting: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text("Waiting for your wallet's signature…")
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(themeManager.currentTheme.textMutedColor)
        }
    }

    private var cancelButton: some View {
        Button(action: dismiss) {
            Text("Cancel")
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(themeManager.currentTheme.textMutedColor)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    let themeManager = ThemeManager.shared
    let flow = NetworkConsentFlow(client: NetworkConsentPreviewClient())
    NetworkConsentSheet(flow: flow, connector: flow.connector, dismiss: {})
        .environmentObject(themeManager)
}
