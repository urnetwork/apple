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
 * One row of the dns picker, as the sdk lists it (`GetDnsPicks`): the values
 * the row shows, copied out of the sdk's pick. A preset pick carries its
 * provider and catalog values; the default, custom and regional picks leave
 * them empty.
 */
struct DnsPickRow: Identifiable {
    let kind: String
    // what the pick selects: "default", a preset id, "regional-<cc>", or
    // empty for Custom
    let presetId: String
    let groupKey: String
    let labelKey: String
    let copyKey: String
    let countryCode: String
    let providerName: String
    let jurisdiction: String
    let privacyUrl: String
    let helpUrl: String
    let personalIdRequired: Bool
    let personalIdExample: String
    let personalIdHelpUrl: String
    let personalIdWhereKey: String
    let personalIdFormatKey: String
    let quotaNoteKey: String

    // Custom is the one pick without a preset id
    var id: String { "\(kind):\(presetId)" }

    init(_ pick: SdkDnsPick) {
        kind = pick.kind
        presetId = pick.presetId
        groupKey = pick.groupKey
        labelKey = pick.labelKey
        copyKey = pick.copyKey
        countryCode = pick.countryCode
        let preset = pick.preset
        providerName = preset?.providerName ?? ""
        jurisdiction = preset?.jurisdiction ?? ""
        privacyUrl = preset?.privacyUrl ?? ""
        helpUrl = preset?.helpUrl ?? ""
        personalIdRequired = preset?.personalIdRequired ?? false
        personalIdExample = preset?.personalIdExample ?? ""
        personalIdHelpUrl = preset?.personalIdHelpUrl ?? ""
        personalIdWhereKey = preset?.personalIdWhereKey ?? ""
        personalIdFormatKey = preset?.personalIdFormatKey ?? ""
        quotaNoteKey = preset?.quotaNoteKey ?? ""
    }
}

/**
 * The picker's rows in the sdk's order (ADBLOCK3RD O9), in sections: a run
 * of picks with the same group heading is one section under it, and a pick
 * without one (URnetwork, Custom, Regional) is a section of its own.
 */
struct DnsPickSection: Identifiable {
    let groupKey: String
    var picks: [DnsPickRow]

    var id: String { picks.first?.id ?? groupKey }

    var containsCustom: Bool {
        picks.contains { $0.kind == SdkDnsPickKindCustom }
    }

    static func sections(_ list: SdkDnsPickList?) -> [DnsPickSection] {
        guard let list else {
            return []
        }
        var sections: [DnsPickSection] = []
        for i in 0..<list.len() {
            guard let sdkPick = list.get(i) else {
                continue
            }
            let pick = DnsPickRow(sdkPick)
            if !pick.groupKey.isEmpty, let last = sections.last, last.groupKey == pick.groupKey {
                sections[sections.count - 1].picks.append(pick)
            } else {
                sections.append(DnsPickSection(groupKey: pick.groupKey, picks: [pick]))
            }
        }
        return sections
    }
}

/**
 * The device's traffic dns (connect ADBLOCK3RD F1, F2): who answers the
 * lookups made through the tunnel.
 *
 * Under the connection region (ingress) the picks: URnetwork's dns, the
 * default everywhere, with no preset ever preselected (N1, H1); the
 * providers' presets by what they block, with "Use my account" for a personal
 * configuration id; Custom, the editor of resolvers and lists; and the exit
 * country's regional pick when it has one, never selected on its own (O6). A
 * pick applies in one tap. The selected preset says
 * where the lookups go, its status, what verification found and, for a
 * filtering one, this connection's blocked lookups. Then Fast DNS on
 * connect, URnetwork's own blocker, and the notes. The sdk lists the picks,
 * describes the selection and its status, and checks a personal id; this
 * view renders what it says and saves through the store, which starts every
 * save from the sdk's helpers (DnsSettingsStore).
 *
 * The custom editor's changes apply together with the Update button. Its
 * draft starts from the settings in force as custom settings, and while the
 * store has none (nil until its first read lands, and after a reset) the
 * screen is disabled: the blank form applied would replace the resolver the
 * extension holds. Update is a compare and set against the store's settings
 * the editor was seeded from; refused, the editor starts over from the
 * store's. A Fast DNS toggle meanwhile moves the seed with it.
 */
struct DnsSettingsView: View {

    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var dnsSettingsStore: DnsSettingsStore
    @EnvironmentObject var deviceManager: DeviceManager
    @Environment(\.dismiss) private var dismiss

    // the width of a pick's selection mark, which its lines below indent past
    private static let markWidth: CGFloat = 20

    // the custom editor: whether it shows, its draft, the custom settings it
    // started from, and the store's settings it was seeded from
    @State private var customOpen = false
    @State private var draft = DnsSettings()
    @State private var customStart: DnsSettings? = nil
    @State private var seed: SettingsEditorSeed<DnsSettings>
    // the personal preset whose id field shows, what was typed in it, and
    // the sdk's error id for it
    @State private var personalIdPresetId: String? = nil
    @State private var personalIdInput = ""
    @State private var personalIdErrorId: String? = nil

    private let connectedCountryCode: String?
    private let connectedCountryName: String?
    private let regionalServers: [RegionalDnsSuggestion]
    private let pickSections: [DnsPickSection]
    // dismisses the screen and opens the location picker, for a preset that
    // fails or does not filter from this exit
    private let changeLocation: (() -> Void)?

    init(
        settings: DnsSettings?,
        connectedCountryCode: String? = nil,
        connectedCountryName: String? = nil,
        changeLocation: (() -> Void)? = nil
    ) {
        let countryCode = connectedCountryCode?.lowercased()
        _seed = State(initialValue: SettingsEditorSeed(settings))
        self.connectedCountryCode = countryCode
        self.connectedCountryName = connectedCountryName
        self.regionalServers = Self.loadRegionalServers()
        self.pickSections = DnsPickSection.sections(SdkGetDnsPicks(countryCode))
        self.changeLocation = changeLocation
    }

    private var customEditable: Bool {
        customStart != nil && seed.editable(with: dnsSettingsStore.settings)
    }

    private var customDirty: Bool {
        guard let customStart else {
            return false
        }
        return draft != customStart
    }

    // custom settings are in force: their editor shows with the screen
    private var customSelected: Bool {
        dnsSettingsStore.selectionSummary(exitCountryCode: connectedCountryCode)?.kind == SdkDnsPickKindCustom
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
        let summary = dnsSettingsStore.selectionSummary(exitCountryCode: connectedCountryCode)
        let status = dnsSettingsStore.statusSummary

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

            ScrollViewReader { proxy in
                Form {

                    // ingress: how the app reaches URnetwork; separate from the
                    // traffic (egress) settings below
                    ConnectionRegionSettingsSection()

                    // the selection in force, as the summary row reads: its
                    // pick may be far down the list, or, for a regional pick
                    // of another exit country, not listed
                    Section {
                        if let summary, let text = dnsSummaryText(summary.summaryKey, provider: summary.providerName) {
                            Text(text)
                                .font(themeManager.currentTheme.bodyFont)
                                .foregroundColor(themeManager.currentTheme.textColor)
                        }
                    } header: {
                        Text("Traffic DNS")
                    }

                    if let summary, summary.dropped {
                        droppedNotice(summary, proxy: proxy)
                    }

                    ForEach(pickSections) { section in
                        Section {
                            ForEach(section.picks) { pick in
                                pickRow(pick, summary: summary, status: status)
                            }
                        } header: {
                            if let heading = dnsGroupHeading(section.groupKey) {
                                sectionHeader(Text(heading))
                            }
                        }

                        // the custom editor right under its pick
                        if customOpen && section.containsCustom {
                            customEditorSections
                        }
                    }

                    fastDnsSection(summary)

                    builtInBlockerSection

                    notesSection

                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .disabled(dnsSettingsStore.settings == nil)
            }

            if customOpen {
                VStack {
                    UrButton(
                        text: "Update",
                        action: {
                            updateCustom()
                        },
                        enabled: customEditable && customDirty
                    )
                }
                .padding()
            }

        }
        .background(themeManager.currentTheme.backgroundColor)
        .onAppear {
            if customSelected {
                openCustomEditor()
            }
        }
        .onChange(of: dnsSettingsStore.settings) { settings in
            if seed.storeChanged(settings) != nil {
                // the store's first settings since the screen opened on none
                if customSelected {
                    openCustomEditor()
                }
            } else if customOpen, let settings, let original = seed.original,
                      settings != original, settings.equalsIgnoringFastDns(original) {
                // the screen's Fast DNS toggle applied: the custom editor
                // compares and sets against the settings with it
                seed.reseed(settings)
            }
        }
    }

    // MARK: the picks

    /**
     * A pick: its name, what it blocks and, for a preset, the operator's
     * jurisdiction and its privacy policy (ADBLOCK3RD F1 item 2). Tapping it
     * selects it, opens the custom editor, or a personal preset's id field.
     * Under the selected preset: where the lookups go (H2), its help, its
     * status, verification and blocked count (C6, C8, I3).
     */
    private func pickRow(_ pick: DnsPickRow, summary: SdkDnsSelectionSummary?, status: SdkDnsStatusSummary?) -> some View {
        // the sdk names the pick to mark: a preset id, "default",
        // "regional-<cc>", or empty for Custom, as the picks name theirs
        let selected = summary?.presetId == pick.presetId
        let presetSelected = selected && pick.kind == SdkDnsPickKindPreset
        let traits: AccessibilityTraits = selected ? [.isButton, .isSelected] : [.isButton]

        return VStack(alignment: .leading, spacing: 8) {

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(selected ? themeManager.currentTheme.accentColor : themeManager.currentTheme.textFaintColor)
                    .frame(width: Self.markWidth)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    pickTitle(pick)

                    if let copy = dnsPickCopy(pick.copyKey, provider: pick.providerName, country: countryName(pick.countryCode)) {
                        Text(copy)
                            .font(themeManager.currentTheme.secondaryBodyFont)
                            .foregroundColor(themeManager.currentTheme.textMutedColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if !pick.jurisdiction.isEmpty {
                        // the jurisdiction is a place, never translated
                        Text("Jurisdiction: \(pick.jurisdiction)")
                            .font(themeManager.currentTheme.secondaryBodyFont)
                            .foregroundColor(themeManager.currentTheme.textFaintColor)
                    }
                }

                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                choose(pick, summary: summary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(traits)

            Group {
                if presetSelected {
                    noteText(Text("Your DNS lookups go to \(pick.providerName) through the tunnel, so it never sees your IP address. Its privacy policy applies."))
                }

                if pick.kind == SdkDnsPickKindPreset {
                    presetLinks(pick, selected: selected)
                }

                if presetSelected, let status {
                    statusLines(status)
                }

                if pick.kind == SdkDnsPickKindCustom && customOpen {
                    noteText(Text("Mixing a filtering server with the default servers doesn't filter: the fastest answer wins."))
                }

                if pick.personalIdRequired && personalIdPresetId == pick.presetId {
                    personalIdEntry(pick)
                }
            }
            .padding(.leading, Self.markWidth + 10)

        }
        .padding(.vertical, 4)
        .id(pick.id)
    }

    private func pickTitle(_ pick: DnsPickRow) -> some View {
        HStack(spacing: 6) {
            if pick.kind == SdkDnsPickKindRegional {
                // the exit country's color, as its suggestions are marked
                Circle()
                    .fill(Color(hex: SdkGetColorHex(pick.countryCode)))
                    .frame(width: 10, height: 10)
            }

            if !pick.providerName.isEmpty {
                // a provider's name is never translated (ADBLOCK3RD G2)
                Text(verbatim: pick.providerName)
            } else if let label = dnsPickLabel(pick.labelKey, country: countryName(pick.countryCode)) {
                Text(label)
            }
        }
        .font(themeManager.currentTheme.bodyFont)
        .foregroundColor(themeManager.currentTheme.textColor)
    }

    /// A preset's privacy policy, and its help while it is selected.
    private func presetLinks(_ pick: DnsPickRow, selected: Bool) -> some View {
        HStack(spacing: 16) {
            if let url = URL(string: pick.privacyUrl) {
                externalLink(Text("Privacy policy"), destination: url)
            }
            if selected, let url = URL(string: pick.helpUrl) {
                externalLink(Text("Help"), destination: url)
            }
        }
    }

    /**
     * The selected preset's status line, with the line under it and the
     * actions of a failing preset, what verification found, and the blocked
     * lookups of a filtering preset (ADBLOCK3RD C6, C8, I3), as the sdk
     * describes them (`DescribeDnsResolverStatus`).
     */
    @ViewBuilder
    private func statusLines(_ status: SdkDnsStatusSummary) -> some View {
        if let line = dnsStatusText(status.statusKey, provider: status.providerName) {
            HStack(alignment: .top, spacing: 6) {
                if status.showUseDefault {
                    // the preset is failing: it fell back or fails closed
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.urCoral)
                        .accessibilityHidden(true)
                }
                Text(line)
                    .font(themeManager.currentTheme.bodyFont)
                    .foregroundColor(themeManager.currentTheme.textColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        if let detail = dnsStatusDetailText(status.statusDetailKey) {
            noteText(Text(detail))
        }

        if status.showUseDefault {
            Button(action: { useDefault() }) {
                Text("Use URnetwork DNS")
                    .font(themeManager.currentTheme.secondaryBodyFont)
            }
            .buttonStyle(.borderless)
        }

        if status.showChangeLocation, let changeLocation {
            Button(action: { changeLocation() }) {
                Text("Change location")
                    .font(themeManager.currentTheme.secondaryBodyFont)
            }
            .buttonStyle(.borderless)
        }

        if let verification = dnsVerificationText(status.verificationKey, provider: status.providerName) {
            noteText(Text(verification))
        }

        if let linkText = dnsDashboardLinkText(status.verificationLinkKey, provider: status.providerName),
           let url = URL(string: status.verificationUrl) {
            externalLink(Text(linkText), destination: url)
        }

        if status.showBlockedCount {
            // counted on the device only, for this connection, and a floor
            VStack(alignment: .leading, spacing: 2) {
                Text("\(Int(dnsSettingsStore.blockedCount)) lookups blocked by \(status.providerName) this connection")
                    .font(themeManager.currentTheme.bodyFont)
                    .foregroundColor(themeManager.currentTheme.textColor)
                    .fixedSize(horizontal: false, vertical: true)
                noteText(Text("Some blocks aren't counted, so the real number may be higher."))
            }
            .onAppear {
                dnsSettingsStore.setBlockedCountShown(true)
            }
            .onDisappear {
                dnsSettingsStore.setBlockedCountShown(false)
            }
        }
    }

    /**
     * A personal preset's id field (ADBLOCK3RD D3): the id, or the dashboard
     * url or Private DNS hostname that holds it, which the sdk reads the id
     * out of and checks (D4). The field never shows the id saved: the screen
     * says "your profile" (D5).
     */
    private func personalIdEntry(_ pick: DnsPickRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {

            Text("Profile ID or DNS address")
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(themeManager.currentTheme.textMutedColor)

            // the provider's own example as the placeholder, as it is
            TextField(pick.personalIdExample, text: $personalIdInput)
                .font(.system(size: 13))
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                #if os(iOS)
                .keyboardType(.asciiCapable)
                .textInputAutocapitalization(.never)
                #endif
                .onSubmit {
                    savePersonalId(pick)
                }

            if let errorId = personalIdErrorId {
                UrInlineErrorText(message: String(localized: dnsPresetErrorMessage(errorId)))
                if errorId == SdkDnsPresetErrorPersonalIdInvalid,
                   let format = dnsPersonalIdFormatText(pick.personalIdFormatKey, provider: pick.providerName, example: pick.personalIdExample) {
                    UrInlineErrorText(message: String(localized: format))
                }
            }

            if let whereText = dnsPersonalIdWhereText(pick.personalIdWhereKey, provider: pick.providerName) {
                noteText(Text(whereText))
            }

            if let quota = dnsPersonalIdQuotaText(pick.quotaNoteKey, provider: pick.providerName) {
                noteText(Text(quota))
            }

            noteText(Text("No need to link an IP address in your dashboard: through URnetwork, your lookups come from an address that isn't yours. Your ID is enough."))

            noteText(Text("In \(pick.providerName), keep the block response at zero IP (0.0.0.0, the default) or NXDOMAIN. REFUSED and other responses look like an outage."))

            HStack(spacing: 16) {
                if let linkText = dnsDashboardLinkText(DnsPresetKey.personalIdDashboardLink, provider: pick.providerName),
                   let url = URL(string: pick.personalIdHelpUrl) {
                    externalLink(Text(linkText), destination: url)
                }
                externalLink(Text("Learn more"), destination: DnsProvidersHelp.personalIdsUrl)
            }

            UrButton(
                text: "Save",
                action: {
                    savePersonalId(pick)
                },
                enabled: !personalIdInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )

        }
        .onChange(of: personalIdInput) { _ in
            personalIdErrorId = nil
        }
    }

    /**
     * The notice of a stored preset this release no longer offers
     * (ADBLOCK3RD A7): URnetwork's dns applies in its place. Choosing another
     * preset, or dismissing the notice, saves URnetwork's dns; Custom opens
     * the editor to enter the provider by hand.
     */
    private func droppedNotice(_ summary: SdkDnsSelectionSummary, proxy: ScrollViewProxy) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {

                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.urCoral)
                        .accessibilityHidden(true)

                    droppedText(summary)
                        .font(themeManager.currentTheme.bodyFont)
                        .foregroundColor(themeManager.currentTheme.textColor)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button(action: { useDefault() }) {
                    Text("Choose another preset")
                        .font(themeManager.currentTheme.secondaryBodyFont)
                }
                .buttonStyle(.borderless)

                Button(action: { enterUnderCustom(proxy) }) {
                    Text("Enter it yourself under Custom")
                        .font(themeManager.currentTheme.secondaryBodyFont)
                }
                .buttonStyle(.borderless)

                Button(action: { useDefault() }) {
                    Text("Got it")
                        .font(themeManager.currentTheme.secondaryBodyFont)
                }
                .buttonStyle(.borderless)

            }
            .padding(.vertical, 4)
        }
    }

    /// The notice names the dropped preset's provider. An id this release
    /// never knew, as after a downgrade, has no name: the generic copy.
    private func droppedText(_ summary: SdkDnsSelectionSummary) -> Text {
        if summary.droppedProviderName.isEmpty {
            return Text("This preset isn't available. Choose another one.")
        }
        return Text("\(summary.droppedProviderName) is no longer available. You're using URnetwork DNS, so lookups aren't filtered.")
    }

    // MARK: the settings under the picks

    /**
     * Fast DNS on connect applies at once, the selection kept. While a
     * preset is selected the connect window uses URnetwork's dns, never the
     * preset (ADBLOCK3RD C7), and the screen says so.
     */
    private func fastDnsSection(_ summary: SdkDnsSelectionSummary?) -> some View {
        Section {
            UrSwitchToggle(isOn: fastDnsOnConnect) {
                toggleLabel("Fast DNS on connect", detail: nil)
            }
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text(FastDnsOnConnectCopy.description)
                if let summary, summary.kind == SdkDnsPickKindPreset {
                    Text("While connecting, lookups use URnetwork DNS, so \(summary.providerName) doesn't filter them.")
                }
            }
            .font(themeManager.currentTheme.secondaryBodyFont)
            .foregroundColor(themeManager.currentTheme.textFaintColor)
        }
    }

    private var fastDnsOnConnect: Binding<Bool> {
        Binding(
            get: {
                dnsSettingsStore.settings?.fastDnsOnConnectEnabled ?? false
            },
            set: { enabled in
                dnsSettingsStore.setFastDnsOnConnect(enabled)
            }
        )
    }

    /// URnetwork's own blocker, beside the providers' (ADBLOCK3RD F1 item
    /// 6): both can be on, and it answers first. The device applies it at
    /// once, as the connect drawer's toggle does.
    private var builtInBlockerSection: some View {
        Section {
            UrSwitchToggle(isOn: $deviceManager.blockerEnabled) {
                toggleLabel("URnetwork ad blocker", detail: nil)
            }
        } footer: {
            Text("URnetwork's own blocker. It works with any DNS choice and checks each name first.")
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(themeManager.currentTheme.textFaintColor)
        }
    }

    /// When a change applies, why a dns profile installed on the device does
    /// not, and the help page (ADBLOCK3RD F1 item 8, F2).
    private var notesSection: some View {
        Section {
            EmptyView()
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Changes apply to new lookups right away. Apps may keep earlier answers for about a minute.")
                    Text("DNS profiles installed on this device don't apply while connected. The DNS chosen here is used instead.")
                }
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(themeManager.currentTheme.textFaintColor)

                externalLink(Text("Learn more"), destination: DnsProvidersHelp.url)
            }
        }
    }

    // MARK: the custom editor

    /// The resolvers, the suggested servers and the four lists, under Custom
    /// (ADBLOCK3RD F2), editing the draft.
    @ViewBuilder
    private var customEditorSections: some View {
        Group {
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
                sectionHeader(Text("Resolvers"))
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
                    sectionHeader(Text("Suggested remote DNS servers"))
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
                placeholder: String(localized: "IP address"),
                validate: Self.isValidIp
            )

            serverListSection(
                "Local DNS servers",
                ipv4: $draft.localDnsIpv4,
                ipv6: $draft.localDnsIpv6,
                placeholder: String(localized: "IP address"),
                validate: Self.isValidIp
            )
        }
        .disabled(!customEditable)
    }

    // MARK: actions

    /// A tap on a pick: URnetwork's dns, a preset or the regional pick apply
    /// at once; Custom opens or closes the editor; a personal preset opens
    /// its id field first.
    private func choose(_ pick: DnsPickRow, summary: SdkDnsSelectionSummary?) {
        if pick.kind == SdkDnsPickKindCustom {
            if !customOpen {
                openCustomEditor()
            } else if summary?.kind != SdkDnsPickKindCustom {
                // custom settings in force keep their editor open
                closeCustomEditor()
            }
            return
        }
        if pick.personalIdRequired {
            if personalIdPresetId == pick.presetId {
                closePersonalIdEntry()
            } else {
                openPersonalIdEntry(pick.presetId)
            }
            return
        }
        closePersonalIdEntry()
        closeCustomEditor()
        // the pick in force applies again only to replace a dropped preset
        if summary?.presetId == pick.presetId && summary?.dropped != true {
            return
        }
        dnsSettingsStore.select(presetId: pick.presetId)
    }

    /// "Use URnetwork DNS", which also dismisses a dropped preset's notice.
    private func useDefault() {
        closePersonalIdEntry()
        closeCustomEditor()
        dnsSettingsStore.select(presetId: SdkDnsPresetIdDefault)
    }

    /// Opens the custom editor and scrolls to it.
    private func enterUnderCustom(_ proxy: ScrollViewProxy) {
        openCustomEditor()
        guard let customId = pickSections.flatMap({ $0.picks }).first(where: { $0.kind == SdkDnsPickKindCustom })?.id else {
            return
        }
        // once the editor is laid out
        DispatchQueue.main.async {
            withAnimation {
                proxy.scrollTo(customId, anchor: .top)
            }
        }
    }

    private func openCustomEditor() {
        guard let settings = dnsSettingsStore.settings, let start = dnsSettingsStore.customDraft() else {
            return
        }
        seed.reseed(settings)
        customStart = start
        draft = start
        customOpen = true
        closePersonalIdEntry()
    }

    private func closeCustomEditor() {
        customOpen = false
        customStart = nil
    }

    private func updateCustom() {
        guard let original = seed.original else {
            return
        }
        if dnsSettingsStore.apply(draft, original: original) {
            dismiss()
        } else if let settings = dnsSettingsStore.settings, let start = dnsSettingsStore.customDraft() {
            // the store's settings moved since the seed: the editor starts
            // over from them
            seed.reseed(settings)
            customStart = start
            draft = start
        }
    }

    private func openPersonalIdEntry(_ presetId: String) {
        personalIdPresetId = presetId
        personalIdInput = ""
        personalIdErrorId = nil
    }

    private func closePersonalIdEntry() {
        personalIdPresetId = nil
        personalIdInput = ""
        personalIdErrorId = nil
    }

    /// Selects the personal preset with the id typed or pasted, once the sdk
    /// finds it valid; else shows the sdk's error.
    private func savePersonalId(_ pick: DnsPickRow) {
        let errorId = SdkValidateDnsPresetPersonalId(pick.presetId, personalIdInput)
        if !errorId.isEmpty {
            personalIdErrorId = errorId
            return
        }
        let personalId = SdkNormalizeDnsPresetPersonalId(pick.presetId, personalIdInput)
        if dnsSettingsStore.select(presetId: pick.presetId, personalId: personalId) {
            closePersonalIdEntry()
            closeCustomEditor()
        } else {
            personalIdErrorId = SdkDnsPresetErrorUnknown
        }
    }

    // MARK: parts

    /// A country's name for the regional pick: the connected country's own,
    /// else its code.
    private func countryName(_ countryCode: String) -> String {
        if countryCode == connectedCountryCode, let name = connectedCountryName, !name.isEmpty {
            return name
        }
        return countryCode.uppercased()
    }

    private func noteText(_ text: Text) -> some View {
        text
            .font(themeManager.currentTheme.secondaryBodyFont)
            .foregroundColor(themeManager.currentTheme.textMutedColor)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// A link that opens in the browser. Borderless, so a row's links and its
    /// tap each take only their own touches.
    private func externalLink(_ title: Text, destination: URL) -> some View {
        Link(destination: destination) {
            HStack(spacing: 4) {
                title
                Image(systemName: "arrow.up.right.square")
                    .accessibilityHidden(true)
            }
            .font(themeManager.currentTheme.secondaryBodyFont)
        }
        .buttonStyle(.borderless)
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

    private func sectionHeader(_ text: Text) -> some View {
        text
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
            sectionHeader(Text(title))
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
