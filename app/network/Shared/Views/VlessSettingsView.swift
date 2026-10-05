//
//  VlessSettingsView.swift
//  URnetwork
//

import SwiftUI
import URnetworkSdk

/**
 * The VLESS settings editor (connect issue 91). Account > Settings > VLESS
 * pushes it; the VLESS row of the login screen's network sheet opens it as a
 * sheet before sign-in. Both edit the network space the app has active.
 *
 * Outcomes show inline, next to the button that caused them, because over the
 * login screen's sheets the app's snackbar is hidden.
 */
struct VlessSettingsView: View {

    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var deviceManager: DeviceManager

    @StateObject private var store = VlessSettingsStore()

    var body: some View {

        ScrollView {

            VStack(alignment: .leading, spacing: 24) {

                VStack(alignment: .leading, spacing: 16) {

                    Text("Connect to URnetwork through your own VLESS server when direct connections are blocked. Your traffic to URnetwork stays encrypted end to end.")
                        .font(themeManager.currentTheme.bodyFont)
                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                        .fixedSize(horizontal: false, vertical: true)

                    UrSwitchToggle(isOn: $store.form.enabled, isEnabled: store.loaded) {
                        Text("Use VLESS")
                            .font(themeManager.currentTheme.bodyFont)
                            .foregroundColor(themeManager.currentTheme.textColor)
                    }

                }

                Divider()
                    .background(themeManager.currentTheme.borderBaseColor)

                linkSection

                Divider()
                    .background(themeManager.currentTheme.borderBaseColor)

                serverSection

                saveSection

            }
            .padding()
            .tabletReadableColumn()

        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            store.setup(deviceManager.networkSpace)
        }
        // a space that becomes active while the screen is open, such as the
        // first one at launch, is loaded; the same space keeps the edits
        .onChange(of: deviceManager.networkSpace) { networkSpace in
            store.setup(networkSpace)
        }
    }

    // MARK: link

    private var linkSection: some View {

        VStack(alignment: .leading, spacing: 12) {

            UrTextField(
                text: $store.link,
                label: "VLESS link",
                placeholder: LocalizedStringKey(VlessSettingsOptions.linkPlaceholder),
                supportingText: "Paste a vless:// link to fill in the settings.",
                isEnabled: store.loaded,
                submitLabel: .done,
                onSubmit: {
                    store.readLink()
                },
                disableCapitalization: true,
                disableAutocorrection: true
            )

            if let linkErrorId = store.linkErrorId {
                UrInlineErrorText(message: String(localized: vlessSettingsErrorMessage(linkErrorId)))
            }

            UrButton(
                text: "Paste link",
                action: pasteLink,
                style: .outlineSecondary,
                enabled: store.loaded,
                leadingSystemImage: "doc.on.clipboard"
            )

            // offered only for settings that validate, which are the only
            // ones the sdk renders as a link
            UrButton(
                text: "Copy link",
                action: copyLink,
                style: .outlineSecondary,
                enabled: store.loaded && store.validationErrorId.isEmpty,
                leadingSystemImage: "doc.on.doc"
            )

            if store.linkCopied {
                Text("VLESS link copied")
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(themeManager.currentTheme.textMutedColor)
            }

        }
    }

    // MARK: server

    private var serverSection: some View {

        VStack(alignment: .leading, spacing: 16) {

            UrTextField(
                text: $store.form.name,
                label: "Name",
                placeholder: "",
                isEnabled: store.loaded
            )

            UrTextField(
                text: $store.form.address,
                label: "Server address",
                placeholder: "",
                isEnabled: store.loaded,
                disableCapitalization: true,
                disableAutocorrection: true
            )

            portField

            UrTextField(
                text: $store.form.id,
                label: "User ID (UUID)",
                placeholder: "",
                isEnabled: store.loaded,
                disableCapitalization: true,
                disableAutocorrection: true
            )

            VlessSettingsPicker(
                label: "Transport",
                selection: $store.form.network,
                options: VlessSettingsOptions.networks,
                isEnabled: store.loaded
            )

            VlessSettingsPicker(
                label: "Security",
                selection: $store.form.security,
                options: VlessSettingsOptions.securities,
                isEnabled: store.loaded
            )

            if store.form.showsFlow {
                VlessSettingsPicker(
                    label: "Flow",
                    selection: $store.form.flow,
                    options: VlessSettingsOptions.flows,
                    isEnabled: store.loaded
                )
            }

            if store.form.showsTlsHandshake {

                UrTextField(
                    text: $store.form.serverName,
                    label: "Server name (SNI)",
                    placeholder: "",
                    isEnabled: store.loaded,
                    disableCapitalization: true,
                    disableAutocorrection: true
                )

                fingerprintPicker

            }

            if store.form.showsTlsOptions {

                UrTextField(
                    text: $store.form.alpn,
                    label: "ALPN",
                    placeholder: "",
                    isEnabled: store.loaded,
                    disableCapitalization: true,
                    disableAutocorrection: true
                )

                UrSwitchToggle(isOn: $store.form.allowInsecure, isEnabled: store.loaded) {
                    Text("Allow an insecure certificate")
                        .font(themeManager.currentTheme.bodyFont)
                        .foregroundColor(themeManager.currentTheme.textColor)
                }

            }

            if store.form.showsReality {

                UrTextField(
                    text: $store.form.publicKey,
                    label: "Public key",
                    placeholder: "",
                    isEnabled: store.loaded,
                    disableCapitalization: true,
                    disableAutocorrection: true
                )

                UrTextField(
                    text: $store.form.shortId,
                    label: "Short ID",
                    placeholder: "",
                    isEnabled: store.loaded,
                    disableCapitalization: true,
                    disableAutocorrection: true
                )

            }

            if store.form.showsHttp {

                UrTextField(
                    text: $store.form.path,
                    label: "Path",
                    placeholder: LocalizedStringKey(VlessSettingsOptions.pathPlaceholder),
                    isEnabled: store.loaded,
                    disableCapitalization: true,
                    disableAutocorrection: true
                )

                UrTextField(
                    text: $store.form.host,
                    label: "Host header",
                    placeholder: "",
                    isEnabled: store.loaded,
                    disableCapitalization: true,
                    disableAutocorrection: true
                )

            }

        }
    }

    @ViewBuilder
    private var portField: some View {
        #if os(iOS)
        UrTextField(
            text: $store.form.port,
            label: "Port",
            placeholder: "",
            isEnabled: store.loaded,
            onTextChange: keepPortDigits,
            keyboardType: .numberPad
        )
        #else
        UrTextField(
            text: $store.form.port,
            label: "Port",
            placeholder: "",
            isEnabled: store.loaded,
            onTextChange: keepPortDigits
        )
        #endif
    }

    /// the empty fingerprint shows as None, the named client hellos as they
    /// are spelled
    private var fingerprintPicker: some View {

        VStack(alignment: .leading, spacing: 8) {

            UrLabel(text: "TLS fingerprint")

            Picker("TLS fingerprint", selection: $store.form.fingerprint) {
                ForEach(VlessSettingsOptions.fingerprints, id: \.self) { fingerprint in
                    if let label = VlessSettingsOptions.fingerprintLabel(fingerprint) {
                        Text(label).tag(fingerprint)
                    } else {
                        Text(verbatim: fingerprint).tag(fingerprint)
                    }
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .tint(themeManager.currentTheme.textColor)
            .disabled(!store.loaded)

        }
    }

    // MARK: save

    private var saveSection: some View {

        VStack(alignment: .leading, spacing: 12) {

            UrButton(
                text: "Save",
                action: {
                    Task {
                        await store.save()
                    }
                },
                enabled: store.loaded,
                isProcessing: store.saving
            )

            switch store.saveOutcome {
            case .saved:
                Text("VLESS settings saved")
                    .font(themeManager.currentTheme.bodyFont)
                    .foregroundColor(themeManager.currentTheme.textColor)
                // the packet tunnel, on iOS and macOS alike, reads the space
                // from its VPN profile when it starts, so a running tunnel
                // keeps the settings it started with
                Text("The VPN uses the new VLESS settings the next time it connects.")
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(themeManager.currentTheme.textMutedColor)
                    .fixedSize(horizontal: false, vertical: true)
            case .failed(let errorId):
                UrInlineErrorText(message: String(localized: vlessSettingsErrorMessage(errorId)))
            case nil:
                EmptyView()
            }

        }
    }

    // MARK: actions

    private func keepPortDigits(_ text: String) {
        let digits = vlessSettingsPortText(text)
        if digits != text {
            store.form.port = digits
        }
    }

    private func pasteLink() {
        #if os(iOS)
        store.pasteLink(UIPasteboard.general.string)
        #elseif os(macOS)
        store.pasteLink(NSPasteboard.general.string(forType: .string))
        #endif
    }

    private func copyLink() {
        guard let link = store.shareLink() else {
            return
        }
        #if os(iOS)
        UIPasteboard.general.string = link
        #elseif os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(link, forType: .string)
        #endif
        store.didCopyLink()
    }
}

/// A labeled segmented picker of the VLESS form, laid out like its text fields.
private struct VlessSettingsPicker: View {

    @EnvironmentObject var themeManager: ThemeManager

    let label: LocalizedStringKey
    @Binding var selection: String
    let options: [VlessSettingsOption]
    let isEnabled: Bool

    var body: some View {

        VStack(alignment: .leading, spacing: 8) {

            UrLabel(text: label)

            Picker(label, selection: $selection) {
                ForEach(options) { option in
                    Text(option.label).tag(option.value)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(!isEnabled)

        }
    }
}
