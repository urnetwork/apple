//
//  DnsSettingsView.swift
//  URnetwork
//
//  Created by Brien Colwell on 7/8/26.
//

import SwiftUI
import Network
import URnetworkSdk

/**
 * A well known regional dns server suggestion
 */
struct RegionalDnsSuggestion: Identifiable {
    let countryCode: String
    let name: String
    let ipv4: String

    var id: String { "\(countryCode)-\(ipv4)" }
}

/**
 * Editor for the device dns resolver settings.
 * Changes apply together with the Update button.
 */
struct DnsSettingsView: View {

    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var dnsSettingsStore: DnsSettingsStore
    @Environment(\.dismiss) private var dismiss

    @State private var draft: DnsSettings
    private let original: DnsSettings
    private let connectedCountryCode: String?
    private let connectedCountryName: String?
    private let regionalServers: [RegionalDnsSuggestion]

    init(settings: DnsSettings?, connectedCountryCode: String? = nil, connectedCountryName: String? = nil) {
        let settings = settings ?? DnsSettings()
        _draft = State(initialValue: settings)
        self.original = settings
        self.connectedCountryCode = connectedCountryCode?.lowercased()
        self.connectedCountryName = connectedCountryName
        self.regionalServers = Self.loadRegionalServers()
    }

    private var isDirty: Bool {
        draft != original
    }

    /**
     * the recommended settings when the connected country has a recommendation
     * (the strong-privacy defaults are known not to work there)
     */
    private var recommendation: DnsSettings? {
        guard let code = connectedCountryCode,
              let sdkSettings = SdkGetRecommendedDnsResolverSettings(code) else {
            return nil
        }
        return DnsSettings(sdkSettings)
    }

    /**
     * the default, most secure settings (encrypted DNS over HTTPS)
     */
    private var defaultSettings: DnsSettings? {
        guard let sdkSettings = SdkGetDefaultDnsResolverSettings() else {
            return nil
        }
        return DnsSettings(sdkSettings)
    }

    private var countryDisplayName: String {
        if let name = connectedCountryName, !name.isEmpty {
            return name
        }
        if let code = connectedCountryCode {
            return code.uppercased()
        }
        return "this region"
    }

    /**
     * suggestions for the connected country first
     */
    private var suggestedServers: [RegionalDnsSuggestion] {
        regionalServers.sorted { a, b in
            let aMatch = a.countryCode == connectedCountryCode
            let bMatch = b.countryCode == connectedCountryCode
            if aMatch != bMatch {
                return aMatch
            }
            if a.countryCode != b.countryCode {
                return a.countryCode < b.countryCode
            }
            return a.name < b.name
        }
    }

    private static func loadRegionalServers() -> [RegionalDnsSuggestion] {
        guard let list = SdkGetRegionalDnsServers() else {
            return []
        }
        var servers: [RegionalDnsSuggestion] = []
        servers.reserveCapacity(list.len())
        for i in 0..<list.len() {
            if let server = list.get(i) {
                servers.append(
                    RegionalDnsSuggestion(
                        countryCode: server.countryCode,
                        name: server.name,
                        ipv4: server.ipv4
                    )
                )
            }
        }
        return servers
    }

    var body: some View {

        VStack(spacing: 0) {

            HStack {
                Text("Custom DNS")
                    .font(themeManager.currentTheme.toolbarTitleFont)
                    .foregroundColor(themeManager.currentTheme.textColor)

                Spacer()

                Button(action: { dismiss() }) {
                    Image(systemName: "xmark")
                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                }
                .buttonStyle(.plain)
            }
            .padding()

            Form {

                if let recommendation = recommendation {
                    if draft == recommendation {
                        // already on the regional recommendation
                        Section {
                            settingsStatusRow(
                                "Using recommended regional settings",
                                showsCountryColor: true
                            )
                        }
                    } else {
                        Section {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("The strongest security rules are known not to work in \(countryDisplayName). There are less secure recommended DNS settings that work better.")
                                    .font(themeManager.currentTheme.secondaryBodyFont)
                                    .foregroundColor(themeManager.currentTheme.textColor)

                                HStack(spacing: 10) {
                                    // the connected country color
                                    Circle()
                                        .fill(Color(hex: SdkGetColorHex(connectedCountryCode ?? "")))
                                        .frame(width: 14, height: 14)

                                    UrButton(
                                        text: "Use recommended settings",
                                        action: {
                                            draft = recommendation
                                        }
                                    )
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                } else if let defaultSettings = defaultSettings {
                    if draft == defaultSettings {
                        // already on the most secure defaults
                        Section {
                            settingsStatusRow(
                                "Using most secure default settings",
                                showsCountryColor: false
                            )
                        }
                    } else {
                        Section {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Restore the most secure settings: encrypted DNS over HTTPS through the tunnel.")
                                    .font(themeManager.currentTheme.secondaryBodyFont)
                                    .foregroundColor(themeManager.currentTheme.textColor)

                                UrButton(
                                    text: "Restore to most secure settings",
                                    action: {
                                        draft = defaultSettings
                                    }
                                )
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                Section {
                    UrSwitchToggle(isOn: $draft.enableRemoteDoh) {
                        toggleLabel("DNS over HTTPS", detail: "remote")
                    }
                    UrSwitchToggle(isOn: $draft.enableLocalDoh) {
                        toggleLabel("DNS over HTTPS", detail: "local")
                    }
                    UrSwitchToggle(isOn: $draft.enableRemoteDns) {
                        toggleLabel("Unencrypted DNS", detail: "remote")
                    }
                    UrSwitchToggle(isOn: $draft.enableLocalDns) {
                        toggleLabel("Unencrypted DNS", detail: "local")
                    }
                } header: {
                    sectionHeader("Resolvers")
                }

                Section {
                    UrSwitchToggle(isOn: $draft.enableFallback) {
                        toggleLabel("Fast DNS on connect", detail: nil)
                    }
                } footer: {
                    Text("Answers DNS over the local network while the tunnel's DNS starts. This can reveal your lookups to the local network. When off, DNS only resolves through the tunnel.")
                        .font(themeManager.currentTheme.secondaryBodyFont)
                        .foregroundColor(themeManager.currentTheme.textFaintColor)
                }

                if !suggestedServers.isEmpty {
                    Section {
                        ForEach(suggestedServers) { server in
                            UrSwitchToggle(isOn: suggestionBinding(server)) {
                                HStack(spacing: 10) {

                                    if server.countryCode == connectedCountryCode {
                                        // suggested for the connected country
                                        Circle()
                                            .fill(Color(hex: SdkGetColorHex(server.countryCode)))
                                            .frame(width: 10, height: 10)
                                    }

                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(server.name)
                                                .font(themeManager.currentTheme.bodyFont)
                                                .foregroundColor(themeManager.currentTheme.textColor)
                                            Text(server.countryCode.uppercased())
                                                .font(.system(size: 10, weight: .medium))
                                                .foregroundColor(themeManager.currentTheme.textFaintColor)
                                        }
                                        Text(server.ipv4)
                                            .font(.system(size: 12).monospacedDigit())
                                            .foregroundColor(themeManager.currentTheme.textMutedColor)
                                    }

                                }
                            }
                        }
                    } header: {
                        sectionHeader("Suggested remote DNS servers")
                    } footer: {
                        Text("Suggestions for the connected country are marked with its color. Turning one on adds it to the remote DNS servers.")
                            .font(themeManager.currentTheme.secondaryBodyFont)
                            .foregroundColor(themeManager.currentTheme.textFaintColor)
                    }
                }

                serverListSection(
                    "Remote DoH URLs",
                    ipv4: $draft.remoteDohUrlsIpv4,
                    ipv6: $draft.remoteDohUrlsIpv6,
                    placeholder: "https://",
                    validate: Self.isValidDohUrl
                )

                serverListSection(
                    "Local DoH URLs",
                    ipv4: $draft.localDohUrlsIpv4,
                    ipv6: $draft.localDohUrlsIpv6,
                    placeholder: "https://",
                    validate: Self.isValidDohUrl
                )

                serverListSection(
                    "Remote DNS servers",
                    ipv4: $draft.remoteDnsIpv4,
                    ipv6: $draft.remoteDnsIpv6,
                    placeholder: "IP address",
                    validate: Self.isValidIp
                )

                serverListSection(
                    "Local DNS servers",
                    ipv4: $draft.localDnsIpv4,
                    ipv6: $draft.localDnsIpv6,
                    placeholder: "IP address",
                    validate: Self.isValidIp
                )

            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            VStack {
                UrButton(
                    text: "Update",
                    action: {
                        dnsSettingsStore.apply(draft)
                        dismiss()
                    },
                    enabled: isDirty
                )
            }
            .padding()

        }
        .background(themeManager.currentTheme.backgroundColor)
    }

    /**
     * A compact status row shown when the current settings already match a
     * suggested configuration, in place of its apply panel.
     */
    private func settingsStatusRow(_ text: LocalizedStringKey, showsCountryColor: Bool) -> some View {
        HStack(spacing: 10) {
            if showsCountryColor {
                Circle()
                    .fill(Color(hex: SdkGetColorHex(connectedCountryCode ?? "")))
                    .frame(width: 14, height: 14)
            } else {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundColor(.urGreen)
            }
            Text(text)
                .font(themeManager.currentTheme.bodyFont)
                .foregroundColor(themeManager.currentTheme.textColor)
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private func toggleLabel(_ title: LocalizedStringKey, detail: LocalizedStringKey?) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(themeManager.currentTheme.bodyFont)
                .foregroundColor(themeManager.currentTheme.textColor)
            if let detail = detail {
                Text(detail)
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(themeManager.currentTheme.textMutedColor)
            }
        }
    }

    private func sectionHeader(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(themeManager.currentTheme.secondaryBodyFont)
            .foregroundColor(themeManager.currentTheme.textMutedColor)
            .textCase(nil)
    }

    private func serverListSection(
        _ title: LocalizedStringKey,
        ipv4: Binding<[String]>,
        ipv6: Binding<[String]>,
        placeholder: String,
        validate: @escaping (String) -> Bool
    ) -> some View {
        Section {
            EditableValueList(
                label: "IPv4",
                values: ipv4,
                placeholder: placeholder,
                validate: validate
            )
            EditableValueList(
                label: "IPv6",
                values: ipv6,
                placeholder: placeholder,
                validate: validate
            )
        } header: {
            sectionHeader(title)
        }
    }

    /**
     * on adds the server to the remote dns list and enables remote dns.
     * off removes it
     */
    private func suggestionBinding(_ server: RegionalDnsSuggestion) -> Binding<Bool> {
        Binding(
            get: {
                draft.remoteDnsIpv4.contains(server.ipv4)
            },
            set: { on in
                if on {
                    if !draft.remoteDnsIpv4.contains(server.ipv4) {
                        draft.remoteDnsIpv4.append(server.ipv4)
                    }
                    draft.enableRemoteDns = true
                } else {
                    draft.remoteDnsIpv4.removeAll { $0 == server.ipv4 }
                }
            }
        )
    }

    static func isValidDohUrl(_ value: String) -> Bool {
        guard let url = URL(string: value) else {
            return false
        }
        return url.scheme == "https" && url.host != nil
    }

    static func isValidIp(_ value: String) -> Bool {
        return IPv4Address(value) != nil || IPv6Address(value) != nil
    }
}

/**
 * An editable list of string values with inline add and remove
 */
struct EditableValueList: View {

    @EnvironmentObject var themeManager: ThemeManager

    let label: LocalizedStringKey
    @Binding var values: [String]
    let placeholder: String
    let validate: (String) -> Bool

    @State private var newValue: String = ""

    private var canAdd: Bool {
        let trimmed = newValue.trimmingCharacters(in: .whitespaces)
        return validate(trimmed) && !values.contains(trimmed)
    }

    var body: some View {

        VStack(alignment: .leading, spacing: 8) {

            HStack {
                Text(label)
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(themeManager.currentTheme.textFaintColor)
                Spacer()
            }

            ForEach(values, id: \.self) { value in
                HStack {
                    Text(value)
                        .font(.system(size: 13).monospacedDigit())
                        .foregroundColor(themeManager.currentTheme.textColor)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer()

                    Button(action: {
                        values.removeAll { $0 == value }
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(themeManager.currentTheme.textFaintColor)
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack {
                TextField(placeholder, text: $newValue)
                    .font(.system(size: 13))
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    #endif
                    .onSubmit {
                        add()
                    }

                Button(action: add) {
                    Image(systemName: "plus.circle.fill")
                        .foregroundColor(
                            canAdd ? .urGreen : themeManager.currentTheme.textFaintColor
                        )
                }
                .buttonStyle(.plain)
                .disabled(!canAdd)
            }

        }
        .padding(.vertical, 2)
    }

    private func add() {
        let trimmed = newValue.trimmingCharacters(in: .whitespaces)
        guard validate(trimmed), !values.contains(trimmed) else {
            return
        }
        values.append(trimmed)
        newValue = ""
    }
}
