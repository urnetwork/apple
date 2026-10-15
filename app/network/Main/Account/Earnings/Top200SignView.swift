//
//  Top200SignView.swift
//  URnetwork
//
//  Sign fleet binding (Earnings › Top 200), on iOS and macOS. The fleet
//  operator builds this device's binding on the ur.io Top 200 page; the user
//  pastes it here (or the page's app link fills it in), checks the fleet ID,
//  hotkey, chain and epochs, and signs it with this device's client key. The
//  screen shows the `{binding, client_signature}` payload to copy back to the
//  page. It also shows this device's client ID and client key and copies its
//  fleet manifest member entry.
//
//  Nothing is sent over the network; only the public client key and the
//  signature leave the screen, and only through the clipboard. The sdk signs
//  the binding digest only, so the screen cannot sign arbitrary data.
//

import SwiftUI
import URnetworkSdk

/// The app's device: the calls go over DeviceLocalRpc to the network
/// extension, which holds the client key.
final class Top200SdkSignDevice: Top200SignDevice, @unchecked Sendable {

    private let device: SdkDeviceRemote

    init(device: SdkDeviceRemote) {
        self.device = device
    }

    func clientId() -> String? {
        device.getClientId()?.idStr
    }

    func clientKey() -> String {
        device.getSnClientKey()
    }

    func signFleetBinding(_ bindingJson: String) throws -> String {
        // gomobile's nonnull string return imports with an error out parameter, not as throws
        var error: NSError?
        let signature = device.signSnFleetBinding(bindingJson, error: &error)
        if let error {
            throw error
        }
        return signature
    }
}

struct Top200SignView: View {

    @EnvironmentObject var themeManager: ThemeManager
    @StateObject private var model: Top200SignModel

    private enum CopiedItem {
        case clientId
        case clientKey
        case member
        case payload
    }

    @State private var copied: CopiedItem? = nil

    init(device: Top200SignDevice, link: Top200SignDestination?) {
        _model = StateObject(wrappedValue: Top200SignModel(device: device, link: link))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Your fleet operator builds this device's binding on the Top 200 page at ur.io. Paste it here to sign it with this device's client key. Nothing is sent: you copy the signed payload back to the page yourself.")
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(themeManager.currentTheme.textMutedColor)

                thisDevice

                bindingField

                if case .valid(_, let binding) = model.check {
                    review(binding)
                }

                UrButton(
                    text: "Sign with this device",
                    action: {
                        Task {
                            await model.sign()
                        }
                    },
                    enabled: model.canSign,
                    isProcessing: model.isSigning
                )

                if let payload = model.payload {
                    signed(payload)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(themeManager.currentTheme.backgroundColor)
        .task {
            await model.load()
        }
    }

    private var thisDevice: some View {
        VStack(alignment: .leading, spacing: 8) {
            UrLabel(text: "This device")
            valueRow(label: "Client ID", value: model.clientId, item: .clientId)
            valueRow(label: "Client key", value: model.clientKey.isEmpty ? nil : model.clientKey, item: .clientKey)
            if model.keyLoaded && model.clientKey.isEmpty {
                errorText(Top200SignError.noKey.message)
            }
            Text("Your fleet manifest lists this device by its client ID and client key. Copy its member entry and send it to your fleet operator.")
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(themeManager.currentTheme.textMutedColor)
            UrButton(
                text: copied == .member ? "Copied!" : "Copy member entry",
                action: {
                    if let entry = model.memberEntry {
                        copy(entry, item: .member)
                    }
                },
                style: .secondary,
                enabled: model.memberEntry != nil
            )
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(themeManager.currentTheme.tintedBackgroundBase)
        .cornerRadius(12)
    }

    private var bindingField: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                UrLabel(text: "Binding to sign")
                Spacer()
                Button(action: {
                    if let text = EarningsClipboard.paste() {
                        model.bindingText = text
                    }
                }) {
                    Text("Paste")
                        .font(themeManager.currentTheme.bodyFont.weight(.semibold))
                        .foregroundColor(themeManager.currentTheme.accentColor)
                }
                .buttonStyle(.plain)
            }
            TextEditor(text: $model.bindingText)
                .font(.system(.footnote, design: .monospaced))
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .scrollContentBackground(.hidden)
                .frame(minHeight: 120)
                .padding(8)
                .background(themeManager.currentTheme.tintedBackgroundBase)
                .cornerRadius(8)
                .accessibilityIdentifier("earnings.top200.sign.binding")
            if let error = model.error {
                errorText(error.message)
            }
        }
    }

    private func review(_ binding: Top200Binding) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Check that the fleet ID, hotkey and epochs match the Top 200 page before you sign.")
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(themeManager.currentTheme.textColor)
            reviewRow(label: "Fleet ID", value: Top200Bindings.shortHex(binding.fleetId))
            reviewRow(label: "Hotkey", value: Top200Bindings.shortHex(binding.hotkey))
            Text("Chain \(binding.chainId) · subnet \(binding.netuid)")
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(themeManager.currentTheme.textColor)
            Text("Valid from epoch \(binding.validFromEpoch) to \(binding.validToEpoch)")
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(themeManager.currentTheme.textColor)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(themeManager.currentTheme.tintedBackgroundBase)
        .cornerRadius(12)
    }

    private func signed(_ payload: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Signed. Copy the payload and paste it on the Top 200 page under Device signature.")
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(themeManager.currentTheme.textColor)
            Text(verbatim: payload)
                .font(.system(.footnote, design: .monospaced))
                .foregroundColor(themeManager.currentTheme.textColor)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(themeManager.currentTheme.tintedBackgroundBase)
                .cornerRadius(8)
            UrButton(
                text: copied == .payload ? "Copied!" : "Copy payload",
                action: {
                    copy(payload, item: .payload)
                }
            )
        }
    }

    private func valueRow(label: LocalizedStringKey, value: String?, item: CopiedItem) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(themeManager.currentTheme.textMutedColor)
            Spacer()
            Text(verbatim: value.map(Top200Bindings.shortHex) ?? "—")
                .font(.system(.body, design: .monospaced))
                .foregroundColor(themeManager.currentTheme.textColor)
            if let value {
                Button(action: {
                    copy(value, item: item)
                }) {
                    Image(systemName: copied == item ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 13))
                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Copy"))
            }
        }
    }

    private func reviewRow(label: LocalizedStringKey, value: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(themeManager.currentTheme.textMutedColor)
            Spacer()
            Text(verbatim: value)
                .font(.system(.body, design: .monospaced))
                .foregroundColor(themeManager.currentTheme.textColor)
        }
    }

    private func errorText(_ message: String) -> some View {
        Text(message)
            .font(themeManager.currentTheme.secondaryBodyFont)
            .foregroundColor(themeManager.currentTheme.dangerColor)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func copy(_ text: String, item: CopiedItem) {
        EarningsClipboard.copy(text)
        copied = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            if copied == item {
                copied = nil
            }
        }
    }
}
