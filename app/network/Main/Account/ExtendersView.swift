//
//  ExtendersView.swift
//  URnetwork
//

import SwiftUI
import URnetworkSdk

/**
 * Account > Extenders (EXTENDER.md K6).
 *
 * The three values of the active network space — the extender dns name, the
 * gossip url and the manual bootstrap hosts — plus the share and import
 * actions of K7, and the legacy single private extender behind Advanced.
 *
 * Empty fields mean the derived default and show it as a placeholder, so
 * clearing a box is how a user goes back to it. Saving restarts the space's
 * network client and node in place; on iOS the tunnel extension picks the
 * values up at its next start, which the screen says.
 */
struct ExtendersView: View {

    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var deviceManager: DeviceManager
    @EnvironmentObject var snackbarManager: UrSnackbarManager

    @StateObject private var store = ExtenderSettingsStore()

    @State private var advancedExpanded: Bool = false
    @State private var presentedSheet: ExtenderSheet? = nil

    private enum ExtenderSheet: String, Identifiable {
        case share
        case `import`

        var id: String { rawValue }
    }

    var body: some View {

        ScrollView {

            VStack(alignment: .leading, spacing: 24) {

                VStack(alignment: .leading, spacing: 16) {

                    UrLabel(text: "Extender settings")

                    UrTextField(
                        text: $store.fields.dnsName,
                        label: "Extender DNS name",
                        placeholder: defaultPlaceholder(store.placeholders.dnsName),
                        supportingText: nil,
                        disableCapitalization: true
                    )

                    UrTextField(
                        text: $store.fields.gossipUrl,
                        label: "Gossip URL",
                        placeholder: defaultPlaceholder(store.placeholders.gossipUrl),
                        supportingText: nil,
                        disableCapitalization: true
                    )

                    VStack(alignment: .leading, spacing: 8) {
                        UrLabel(text: "Extender hosts")
                        UrTextEditor(text: $store.fields.hostsText)
                        Text("One hostname or IP address per line. These are added to the discovered extenders.")
                            .font(themeManager.currentTheme.secondaryBodyFont)
                            .foregroundColor(themeManager.currentTheme.textMutedColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    UrButton(
                        text: "Save",
                        action: save,
                        enabled: store.loaded
                    )
                    .accessibilityIdentifier("acceptance.extenders.save")

                    #if os(iOS)
                    // the packet tunnel extension reads these at its next
                    // start, so a running tunnel keeps what it started with
                    Text("The tunnel uses new extender settings the next time it connects.")
                        .font(themeManager.currentTheme.secondaryBodyFont)
                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                        .fixedSize(horizontal: false, vertical: true)
                    #endif

                }

                Divider()
                    .background(themeManager.currentTheme.borderBaseColor)

                VStack(alignment: .leading, spacing: 12) {

                    UrButton(
                        text: "Share extenders",
                        action: { presentedSheet = .share },
                        style: .outlineSecondary,
                        leadingSystemImage: "qrcode"
                    )

                    UrButton(
                        text: "Import extenders",
                        action: { presentedSheet = .import },
                        style: .outlineSecondary,
                        leadingSystemImage: "qrcode.viewfinder"
                    )

                }

                Divider()
                    .background(themeManager.currentTheme.borderBaseColor)

                /**
                 * The legacy single private extender. It overrides every
                 * discovered extender while it is set, which is why it is
                 * behind a disclosure and says so.
                 */
                DisclosureGroup(isExpanded: $advancedExpanded) {

                    VStack(alignment: .leading, spacing: 16) {

                        Spacer().frame(height: 4)

                        UrLabel(text: "Private extender")

                        Text("A private extender replaces every discovered extender. Leave it empty to use discovery.")
                            .font(themeManager.currentTheme.secondaryBodyFont)
                            .foregroundColor(themeManager.currentTheme.textMutedColor)
                            .fixedSize(horizontal: false, vertical: true)

                        UrTextField(
                            text: $store.privateExtender.ip,
                            label: "IP address",
                            placeholder: "IP address",
                            supportingText: nil,
                            disableCapitalization: true
                        )

                        UrTextField(
                            text: $store.privateExtender.secret,
                            label: "Secret",
                            placeholder: "Secret",
                            supportingText: nil,
                            disableCapitalization: true
                        )

                    }

                } label: {
                    Text("Advanced")
                        .font(themeManager.currentTheme.bodyFont)
                        .foregroundColor(themeManager.currentTheme.textColor)
                }
                .tint(themeManager.currentTheme.textMutedColor)

            }
            .padding()
            .tabletReadableColumn()

        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            store.setup(deviceManager)
        }
        .onDisappear {
            store.reset()
        }
        .sheet(item: $presentedSheet) { sheet in
            Group {
                switch sheet {
                case .share:
                    ShareExtendersView(store: store)
                case .import:
                    ImportExtendersView(store: store)
                }
            }
            .environmentObject(themeManager)
            .environmentObject(snackbarManager)
        }
    }

    /// The placeholder of an empty field: the default that applies when the
    /// field is left empty (K6). A space that derives nothing shows nothing.
    private func defaultPlaceholder(_ value: String) -> LocalizedStringKey {
        value.isEmpty ? "" : "Default: \(value)"
    }

    private func save() {
        store.save()
        snackbarManager.showSnackbar(message: String(localized: "Extender settings saved"))
    }
}
