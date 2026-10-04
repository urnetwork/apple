//
//  ConnectBittensorWalletSheet.swift
//  URnetwork
//
//  The sheet that attaches a Bittensor coldkey: choose the wallet (Talisman,
//  TAO.com or WalletConnect), then sign through the browser bridge or paste an address and the
//  signature for it. Shows the address checks (checking, new-wallet warning,
//  blocked) and the errors.
//

import SwiftUI
import URnetworkSdk

struct ConnectBittensorWalletSheet: View {

    @EnvironmentObject var themeManager: ThemeManager
    @ObservedObject var flow: ConnectBittensorWalletFlow
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Bittensor wallet")
                    .font(themeManager.currentTheme.toolbarTitleFont)
                    .foregroundColor(themeManager.currentTheme.textColor)
                Spacer()
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
            WalletNotRetroactiveNote()
            Text("Choose your Bittensor wallet")
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(themeManager.currentTheme.textColor)
            ForEach(BittensorWallet.walletIds, id: \.self) { walletId in
                UrButton(
                    text: LocalizedStringKey(BittensorWallet.displayName(walletId)),
                    action: {
                        Task {
                            await flow.chooseWallet(walletId)
                        }
                    },
                    style: .secondary,
                    accessibilityIdentifier: "earnings.bittensor.wallet.\(walletId)"
                )
                if walletId == SdkBittensorWalletWalletConnect {
                    Text("Nova, Nightly and other WalletConnect wallets")
                        .font(themeManager.currentTheme.secondaryBodyFont)
                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                        .frame(maxWidth: .infinity)
                }
            }

        case .manualEntry:
            WalletNotRetroactiveNote()
            TextField("", text: $flow.manualAddress, prompt: Text("Enter a Bittensor address"))
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            UrButton(
                text: "Continue",
                action: {
                    Task {
                        await flow.submitManualAddress()
                    }
                },
                enabled: !flow.manualAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
            cancelButton

        case .checking:
            HStack(spacing: 12) {
                ProgressView()
                Text("Checking address…")
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(themeManager.currentTheme.textMutedColor)
            }

        case .newWalletWarning:
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.urAmber)
                Text("This address has no activity on the Bittensor chain yet. It looks like a new wallet. Make sure it is yours before continuing.")
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(themeManager.currentTheme.textColor)
            }
            if let address = flow.address {
                Text(verbatim: address)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundColor(themeManager.currentTheme.textMutedColor)
            }
            UrButton(text: "Continue", action: {
                Task {
                    await flow.continueAnyway()
                }
            })
            cancelButton

        case .blocked:
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "xmark.octagon.fill")
                    .foregroundColor(themeManager.currentTheme.dangerColor)
                Text("This wallet can't be used with URnetwork.")
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(themeManager.currentTheme.textColor)
            }
            UrButton(text: "Close", action: dismiss)

        case .signing:
            BittensorWalletSignView(
                connector: flow.connector,
                onChoose: { walletId in
                    Task {
                        await flow.chooseWallet(walletId)
                    }
                },
                onCancel: {
                    flow.reset()
                }
            )

        case .connecting:
            HStack(spacing: 12) {
                ProgressView()
                Text("Connect Bittensor wallet")
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(themeManager.currentTheme.textMutedColor)
            }

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
}

#Preview {
    let themeManager = ThemeManager.shared
    let client = EarningsPreviewClient()
    ConnectBittensorWalletSheet(
        flow: ConnectBittensorWalletFlow(client: client, connect: { address, signature, message in
            try await client.connectWallet(coldkeySs58: address, signature: signature, message: message)
        }),
        dismiss: {}
    )
    .environmentObject(themeManager)
}
