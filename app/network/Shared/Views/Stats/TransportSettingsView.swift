//
//  TransportSettingsView.swift
//  URnetwork
//

import SwiftUI
import URnetworkSdk

/**
 * Editor for the device transport settings: one carrier, or auto with a
 * per-carrier enable. The auto preference order is the SDK default and is not
 * user-managed. Changes apply together with the Update button.
 *
 * The draft is an SDK policy object edited through the SDK's helpers (a newly
 * enabled carrier takes its default priority; the last enabled carrier can't
 * be disabled), with a render snapshot re-taken after every edit, so the
 * editing rules live in one place for every platform.
 */
struct TransportSettingsView: View {

    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var transportSettingsStore: TransportSettingsStore
    @Environment(\.dismiss) private var dismiss

    let kind: TransportSettingsKind

    // the sdk draft policy and its render snapshot
    @State private var sdkDraft: SdkTransportSettings
    @State private var draft: TransportSettings
    private let sdkOriginal: SdkTransportSettings

    init(kind: TransportSettingsKind, settings: TransportSettings?) {
        self.kind = kind
        let original = (settings ?? kind.defaultSettings).sdk
        self.sdkOriginal = original
        let sdkDraft = original.clone() ?? original
        _sdkDraft = State(initialValue: sdkDraft)
        _draft = State(initialValue: TransportSettings(sdkDraft))
    }

    private var isDirty: Bool {
        !sdkDraft.equals(sdkOriginal)
    }

    private var isDefault: Bool {
        sdkDraft.equals(kind.defaultSettings.sdk)
    }

    private var title: LocalizedStringKey {
        switch kind {
        case .client: return "Transports"
        case .provider: return "Provider transports"
        }
    }

    var body: some View {

        VStack(spacing: 0) {

            HStack {
                Text(title)
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

                Section {
                    modeRow(nil)
                    ForEach(TransportType.selectable) { transport in
                        modeRow(transport)
                    }
                } header: {
                    sectionHeader("Transport")
                } footer: {
                    Group {
                        switch kind {
                        case .client:
                            Text("The transport this device uses to reach providers. Auto tries the enabled transports in preference order and keeps every healthy transport of the same tier connected in parallel.")
                        case .provider:
                            Text("The transport this device uses while providing for others. Auto tries the enabled transports in preference order and keeps every healthy transport of the same tier connected in parallel.")
                        }
                    }
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(themeManager.currentTheme.textFaintColor)
                }

                if draft.isAuto {
                    Section {
                        ForEach(TransportType.selectable) { transport in
                            UrSwitchToggle(
                                isOn: autoBinding(transport),
                                // the last enabled carrier can't be turned off (the
                                // sdk refuses the edit: an empty auto policy would
                                // resolve to the full default), so show it disabled
                                isEnabled: !(draft.isAutoEnabled(transport) && draft.autoTransports.count == 1)
                            ) {
                                transportLabel(transport, showsDetail: false)
                            }
                        }
                    } header: {
                        sectionHeader("Enabled under Auto")
                    } footer: {
                        Text("Listed in preference order: H3 and H1 first, then whodis, then whodis pump. The order is fixed. At least one transport stays enabled.")
                            .font(themeManager.currentTheme.secondaryBodyFont)
                            .foregroundColor(themeManager.currentTheme.textFaintColor)
                    }
                }

                if !isDefault {
                    Section {
                        UrButton(
                            text: "Restore default transports",
                            action: {
                                let sdkDefault = kind.defaultSettings.sdk
                                sdkDraft = sdkDefault.clone() ?? sdkDefault
                                draft = TransportSettings(sdkDraft)
                            },
                            style: .outlineSecondary
                        )
                        .padding(.vertical, 4)
                    }
                }

            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            VStack {
                UrButton(
                    text: "Update",
                    action: {
                        transportSettingsStore.apply(sdkDraft, kind: kind)
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
     * A selectable row for one transport mode: nil is auto
     */
    private func modeRow(_ transport: TransportType?) -> some View {
        let selected = draft.singleTransport == transport
        return Button(action: {
            sdkDraft.mode = transport?.rawValue ?? SdkTransportModeAuto
            draft = TransportSettings(sdkDraft)
        }) {
            HStack(spacing: 10) {
                if let transport {
                    transportLabel(transport, showsDetail: true)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Auto")
                            .font(themeManager.currentTheme.bodyFont)
                            .foregroundColor(themeManager.currentTheme.textColor)
                        Text("Recommended. Uses the enabled transports below.")
                            .font(themeManager.currentTheme.secondaryBodyFont)
                            .foregroundColor(themeManager.currentTheme.textMutedColor)
                    }
                }

                Spacer()

                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.urGreen)
                    .opacity(selected ? 1 : 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func transportLabel(_ transport: TransportType, showsDetail: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(transport.color(themeManager.currentTheme))
                .frame(width: 10, height: 10)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                transport.label
                    .font(themeManager.currentTheme.bodyFont)
                    .foregroundColor(themeManager.currentTheme.textColor)
                if showsDetail, let detail = transport.detail {
                    Text(detail)
                        .font(themeManager.currentTheme.secondaryBodyFont)
                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func sectionHeader(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(themeManager.currentTheme.secondaryBodyFont)
            .foregroundColor(themeManager.currentTheme.textMutedColor)
            .textCase(nil)
    }

    /**
     * on/off for one carrier under auto, applied through the sdk so the
     * default-priority and last-carrier rules are the sdk's
     */
    private func autoBinding(_ transport: TransportType) -> Binding<Bool> {
        Binding(
            get: {
                draft.isAutoEnabled(transport)
            },
            set: { enabled in
                if sdkDraft.setAutoModeEnabled(transport.rawValue, enabled: enabled) {
                    draft = TransportSettings(sdkDraft)
                }
            }
        )
    }
}

#Preview {
    TransportSettingsView(kind: .client, settings: nil)
        .environmentObject(ThemeManager.shared)
        .environmentObject(TransportSettingsStore())
}
