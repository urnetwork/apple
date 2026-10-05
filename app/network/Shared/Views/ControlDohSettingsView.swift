//
//  ControlDohSettingsView.swift
//  URnetwork
//

import SwiftUI
import URnetworkSdk

/**
 * The bootstrap DNS-over-HTTPS servers block (P216): the description, which
 * names what the chosen servers can see and so always shows, the field with
 * one url per line, the "Use China resolvers" preset, the reset to the
 * built-in servers, and Save. An empty field means the built-in servers alone.
 *
 * Account > Extenders shows it below the extender settings, disabled with
 * them. Outcomes show inline, next to the buttons, because over the login
 * screen's sheets the app's snackbar is hidden.
 */
struct ControlDohSettingsSection: View {

    @EnvironmentObject var themeManager: ThemeManager

    @ObservedObject var store: ControlDohSettingsStore
    var enabled: Bool
    /// the login sheet's container carries the title instead
    var showsTitle: Bool = true

    var body: some View {

        VStack(alignment: .leading, spacing: 16) {

            if showsTitle {
                UrLabel(text: "Bootstrap DNS-over-HTTPS servers")
            }

            Text("URnetwork looks up the names of its own servers over DNS-over-HTTPS. If the built-in servers are blocked on your network, add servers that work there. URnetwork tries them first, and they can see these lookups.")
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(themeManager.currentTheme.textMutedColor)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {

                UrTextEditor(text: $store.text, enabled: enabled)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif

                Text("One URL per line, starting with https:// and an IP address, such as https://223.5.5.5/dns-query.")
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(themeManager.currentTheme.textMutedColor)
                    .fixedSize(horizontal: false, vertical: true)

                if let errorId = store.errorId {
                    UrInlineErrorText(message: String(localized: controlDohErrorMessage(errorId)))
                }

            }

            VStack(alignment: .leading, spacing: 8) {

                UrButton(
                    text: "Use China resolvers",
                    action: {
                        store.useChinaPreset()
                    },
                    style: .outlineSecondary,
                    enabled: enabled
                )

                Text("Fills in the AliDNS and DNSPod servers, which are reachable in mainland China.")
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(themeManager.currentTheme.textMutedColor)
                    .fixedSize(horizontal: false, vertical: true)

            }

            UrButton(
                text: "Use built-in servers only",
                action: {
                    Task {
                        await store.reset()
                    }
                },
                style: .outlineSecondary,
                enabled: enabled
            )

            UrButton(
                text: "Save",
                action: {
                    Task {
                        await store.save()
                    }
                },
                enabled: enabled,
                isProcessing: store.saving
            )

            if store.saveOutcome == .saved {
                Text("Bootstrap DNS-over-HTTPS servers saved")
                    .font(themeManager.currentTheme.bodyFont)
                    .foregroundColor(themeManager.currentTheme.textColor)
                // the packet tunnel, on iOS and macOS alike, reads the space
                // from the app group when it starts, so a running tunnel keeps
                // the servers it started with
                Text("The VPN uses the new bootstrap servers the next time it connects.")
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(themeManager.currentTheme.textMutedColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

        }
    }
}

/**
 * The block on its own, for the login screen's network sheet: the active
 * network space's servers before sign-in. Where the default DoH servers are
 * blocked (mainland China), sign-in cannot reach the api without them.
 */
struct ControlDohSettingsView: View {

    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var deviceManager: DeviceManager

    @StateObject private var store = ControlDohSettingsStore()

    var body: some View {

        ScrollView {

            ControlDohSettingsSection(
                store: store,
                enabled: store.loaded,
                showsTitle: false
            )
            .padding()
            .tabletReadableColumn()

        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            store.setup(deviceManager.networkSpace)
        }
        // a space that becomes active while the sheet is open, such as the
        // first one at launch, is loaded; the same space keeps the edits
        .onChange(of: deviceManager.networkSpace) { networkSpace in
            store.setup(networkSpace)
        }
    }
}
