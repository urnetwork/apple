//
//  WalletDisconnectSheet.swift
//  URnetwork
//
//  Disconnect the network's payout wallet (sdk api_sn_wallet_disconnect.go),
//  from the Bittensor wallet card while the wallet read says the owner can
//  (SnGetWalletResult.Disconnectable: a wallet connected without a signed
//  payout consent). The sheet says plainly that with no payout wallet the
//  earnings can't be paid out, emails a code to the account's sign-in
//  addresses, and disconnects with it. The server decides again and words a
//  refusal with its code (SnWalletDisconnectErrorCode*), which this sheet
//  words in turn, falling back to the server's message.
//

import SwiftUI
import URnetworkSdk

@MainActor
final class WalletDisconnectModel: ObservableObject {

    enum Step: Equatable {
        /// what disconnecting means, before a code is sent
        case confirm
        /// the code went to these masked addresses, joined with ", "
        case enterCode(sentTo: String)
    }

    /// An answer that ends the sheet: the card reads the wallet again.
    enum Ending: Equatable {
        /// the network has no payout wallet now
        case disconnected
        /// the server has no wallet to disconnect (no_wallet)
        case noWallet
    }

    @Published private(set) var step: Step = .confirm
    @Published var code: String = "" {
        didSet {
            errorMessage = nil
        }
    }
    @Published private(set) var isBusy = false
    @Published private(set) var errorMessage: String?

    private let client: EarningsClient

    init(client: EarningsClient) {
        self.client = client
    }

    var canDisconnect: Bool {
        !isBusy && !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Emails the code; nil while the sheet stays.
    func sendCode() async -> Ending? {
        guard !isBusy else {
            return nil
        }
        isBusy = true
        errorMessage = nil
        let (result, err) = await client.walletDisconnectCode()
        isBusy = false
        if let err {
            print("[WalletDisconnect] code request error: \(err.localizedDescription)")
            errorMessage = Self.genericText
            return nil
        }
        guard let result else {
            errorMessage = Self.genericText
            return nil
        }
        if let error = result.error {
            if error.code == SdkSnWalletDisconnectErrorCodeNoWallet {
                return .noWallet
            }
            errorMessage = Self.text(code: error.code, message: error.message)
            return nil
        }
        code = ""
        step = .enterCode(sentTo: Self.joined(result.sentTo))
        return nil
    }

    /// Disconnects with the entered code; nil while the sheet stays.
    func disconnect() async -> Ending? {
        guard case .enterCode = step, canDisconnect else {
            return nil
        }
        isBusy = true
        errorMessage = nil
        let (result, err) = await client.walletDisconnect(code: code)
        isBusy = false
        if let err {
            print("[WalletDisconnect] disconnect request error: \(err.localizedDescription)")
            errorMessage = Self.genericText
            return nil
        }
        guard let result else {
            errorMessage = Self.genericText
            return nil
        }
        if let error = result.error {
            switch error.code {
            case SdkSnWalletDisconnectErrorCodeNoWallet:
                return .noWallet
            case SdkSnWalletDisconnectErrorCodeCodeExpired:
                // no code waits any more: back to sending one
                step = .confirm
            default:
                // a wrong code keeps the field
                break
            }
            errorMessage = Self.text(code: error.code, message: error.message)
            return nil
        }
        if result.disconnected {
            return .disconnected
        }
        errorMessage = Self.genericText
        return nil
    }

    static var genericText: String {
        String(localized: "Something went wrong. Please try again later.")
    }

    /// The words for a refusal's code; the server's message for owner_only
    /// and for a code this app does not know.
    static func text(code: String, message: String) -> String {
        switch code {
        case SdkSnWalletDisconnectErrorCodeConsentInForce:
            return String(localized: "Your signed payout consent sends your earnings to this wallet, and only another signed consent can replace it. Use Change wallet instead.")
        case SdkSnWalletDisconnectErrorCodeEmailRequired:
            return String(localized: "Add an email sign-in to your account first. The confirmation code is sent to it.")
        case SdkSnWalletDisconnectErrorCodeRateLimited:
            return String(localized: "Too many tries. Please try again later.")
        case SdkSnWalletDisconnectErrorCodeSendFailed:
            return String(localized: "The code could not be sent. Please try again.")
        case SdkSnWalletDisconnectErrorCodeCodeInvalid:
            return String(localized: "That code is wrong. Check it and try again.")
        case SdkSnWalletDisconnectErrorCodeCodeExpired:
            return String(localized: "That code expired or was already used. Ask for a new one.")
        default:
            return message.isEmpty ? genericText : message
        }
    }

    /// The masked addresses the code went to, joined with ", ".
    static func joined(_ addresses: SdkStringList?) -> String {
        guard let addresses else {
            return ""
        }
        var values: [String] = []
        for i in 0..<addresses.len() {
            values.append(addresses.get(i))
        }
        return values.joined(separator: ", ")
    }
}

struct WalletDisconnectSheet: View {

    @EnvironmentObject var themeManager: ThemeManager
    @StateObject private var model: WalletDisconnectModel
    let dismiss: () -> Void
    /// the sheet's work ended: the card reads the wallet again, and confirms
    /// the disconnect
    let ended: (WalletDisconnectModel.Ending) -> Void

    init(client: EarningsClient, dismiss: @escaping () -> Void, ended: @escaping (WalletDisconnectModel.Ending) -> Void) {
        _model = StateObject(wrappedValue: WalletDisconnectModel(client: client))
        self.dismiss = dismiss
        self.ended = ended
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Disconnect your payout wallet?")
                    .font(themeManager.currentTheme.toolbarTitleFont)
                    .foregroundColor(themeManager.currentTheme.textColor)
                    .fixedSize(horizontal: false, vertical: true)

                switch model.step {
                case .confirm:
                    Text("With no payout wallet, your earnings can't be paid out. Earnings already paid stay claimable by the wallet they were paid to. To confirm, we'll email a code to your account.")
                        .font(themeManager.currentTheme.secondaryBodyFont)
                        .foregroundColor(themeManager.currentTheme.textColor)
                        .fixedSize(horizontal: false, vertical: true)
                    errorLine
                    UrButton(
                        text: "Email me a code",
                        action: {
                            Task {
                                if let ending = await model.sendCode() {
                                    ended(ending)
                                }
                            }
                        },
                        enabled: !model.isBusy,
                        isProcessing: model.isBusy,
                        accessibilityIdentifier: "earnings.wallet.disconnect.sendCode"
                    )
                case .enterCode(let sentTo):
                    Text("We sent a code to \(sentTo). Enter it to disconnect the wallet.")
                        .font(themeManager.currentTheme.secondaryBodyFont)
                        .foregroundColor(themeManager.currentTheme.textColor)
                        .fixedSize(horizontal: false, vertical: true)
                    #if os(iOS)
                    UrTextField(
                        text: $model.code,
                        label: "Code",
                        placeholder: "",
                        isEnabled: !model.isBusy,
                        keyboardType: .numberPad,
                        disableCapitalization: true,
                        disableAutocorrection: true
                    )
                    #else
                    UrTextField(
                        text: $model.code,
                        label: "Code",
                        placeholder: "",
                        isEnabled: !model.isBusy,
                        disableCapitalization: true,
                        disableAutocorrection: true
                    )
                    #endif
                    errorLine
                    BittensorKeyDestructiveButton(
                        text: "Disconnect wallet",
                        enabled: model.canDisconnect,
                        isProcessing: model.isBusy,
                        accessibilityIdentifier: "earnings.wallet.disconnect.confirm",
                        action: {
                            Task {
                                if let ending = await model.disconnect() {
                                    ended(ending)
                                }
                            }
                        }
                    )
                }

                Button(action: dismiss) {
                    Text("Cancel")
                        .font(themeManager.currentTheme.secondaryBodyFont)
                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .disabled(model.isBusy)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(themeManager.currentTheme.backgroundColor)
    }

    @ViewBuilder
    private var errorLine: some View {
        if let error = model.errorMessage {
            Text(verbatim: error)
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(themeManager.currentTheme.dangerColor)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
