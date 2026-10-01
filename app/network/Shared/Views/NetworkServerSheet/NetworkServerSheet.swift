//
//  NetworkServerSheet.swift
//  URnetwork
//
//  "Change Network API" sheet - lets the user point the app at a different
//  network domain (self-hosted or alternate) instead of the official
//  bringyour.com, or enter explicit API/connect url overrides. Available on
//  both iOS and macOS (unlike the Solana wallet sign-in flow, which is
//  iOS-only). Ported from Android's `NetworkServerSelector.kt`.
//

import SwiftUI

struct NetworkServerSheet: View {

    @EnvironmentObject var themeManager: ThemeManager
    @StateObject private var viewModel: ViewModel

    var currentApiUrl: String
    var currentConnectUrl: String
    var managerAvailable: Bool
    var onApply: (_ hostName: String, _ apiUrl: String, _ connectUrl: String) -> Bool
    var dismiss: () -> Void

    init(
        initialHostName: String,
        currentApiUrl: String,
        currentConnectUrl: String,
        configuredApiUrl: String,
        configuredConnectUrl: String,
        managerAvailable: Bool,
        onApply: @escaping (_ hostName: String, _ apiUrl: String, _ connectUrl: String) -> Bool,
        dismiss: @escaping () -> Void
    ) {
        self._viewModel = .init(wrappedValue: .init(
            initialHostName: initialHostName,
            configuredApiUrl: configuredApiUrl,
            configuredConnectUrl: configuredConnectUrl
        ))
        self.currentApiUrl = currentApiUrl
        self.currentConnectUrl = currentConnectUrl
        self.managerAvailable = managerAvailable
        self.onApply = onApply
        self.dismiss = dismiss
    }

    var body: some View {
        VStack(alignment: .leading) {

            Spacer().frame(height: 24)

            HStack {
                Text("Change Network API")
                    .font(themeManager.currentTheme.toolbarTitleFont)

                Spacer()

                #if os(macOS)
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                #endif
            }

            Spacer().frame(height: 8)

            Text("Choose the network domain used by the app. Leave the API and connect URLs blank to derive them from the domain.")
                .font(themeManager.currentTheme.bodyFont)
                .foregroundColor(themeManager.currentTheme.textMutedColor)

            Spacer().frame(height: 16)

            Text("Current API: \(currentApiUrl)")
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(themeManager.currentTheme.textMutedColor)

            Text("Current connect: \(currentConnectUrl)")
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(themeManager.currentTheme.textMutedColor)

            Spacer().frame(height: 20)

            UrTextField(
                text: $viewModel.hostName,
                label: "Network domain",
                placeholder: LocalizedStringKey(viewModel.officialHostName),
                supportingText: "Example: bringyour.com or your custom domain.",
                isEnabled: managerAvailable
            )

            Spacer().frame(height: 16)

            UrTextField(
                text: $viewModel.apiUrl,
                label: "API URL (optional)",
                placeholder: LocalizedStringKey(viewModel.derivedApiUrl),
                supportingText: "Leave blank to derive from the network domain.",
                isEnabled: managerAvailable
            )

            Spacer().frame(height: 16)

            UrTextField(
                text: $viewModel.connectUrl,
                label: "Connect URL (optional)",
                placeholder: LocalizedStringKey(viewModel.derivedConnectUrl),
                supportingText: "Use wss:// for secure custom connect servers.",
                isEnabled: managerAvailable
            )

            if viewModel.showInsecureEndpointWarning {
                Spacer().frame(height: 12)
                Text("Warning: one or more custom endpoints are not using HTTPS/WSS. Traffic may be unencrypted.")
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(themeManager.currentTheme.dangerColor)
            }

            Spacer().frame(height: 20)

            UrButton(
                text: "Use default network",
                action: {
                    let (hostName, apiUrl, connectUrl) = viewModel.resetToDefault()
                    apply(hostName: hostName, apiUrl: apiUrl, connectUrl: connectUrl)
                },
                style: .outlineSecondary,
                enabled: managerAvailable
            )

            Spacer().frame(height: 12)

            UrButton(
                text: "Apply Network API",
                action: {
                    apply(hostName: viewModel.hostName, apiUrl: viewModel.apiUrl, connectUrl: viewModel.connectUrl)
                },
                enabled: managerAvailable
            )

            if !managerAvailable {
                Spacer().frame(height: 12)
                UrInlineErrorText(message: "Network manager unavailable")
            }

            if let statusMessage = viewModel.statusMessage {
                Spacer().frame(height: 12)
                Text(statusMessage)
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(themeManager.currentTheme.textMutedColor)
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 24)
    }

    private func apply(hostName: String, apiUrl: String, connectUrl: String) {
        let normalizedHost = NetworkServerUtils.normalizeNetworkHost(hostName)
        guard !normalizedHost.isEmpty else {
            viewModel.setStatusMessage("Enter a network domain")
            return
        }

        let normalizedApiUrl = NetworkServerUtils.normalizeApiUrl(apiUrl)
        let normalizedConnectUrl = NetworkServerUtils.normalizeConnectUrl(connectUrl)

        let applied = onApply(normalizedHost, normalizedApiUrl, normalizedConnectUrl)
        if applied {
            viewModel.setStatusMessage("Switched to \(normalizedHost)")
            dismiss()
        } else {
            viewModel.setStatusMessage("Network manager unavailable")
        }
    }
}
