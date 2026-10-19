//
//  ConnectionRegionPicker.swift
//  URnetwork
//
//  The connection region picker (see ConnectionRegionStore), shared by the
//  login screen control, the can't-reach prompt and the DNS settings.
//

import SwiftUI
import URnetworkSdk

/// "Where are you connecting from?": the regions with a recommendation and
/// Other / Undisclosed, each with the resolvers it uses.
struct ConnectionRegionPickerSheet: View {

    @EnvironmentObject var themeManager: ThemeManager
    @ObservedObject var store: ConnectionRegionStore
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Where are you connecting from?")
                    .font(themeManager.currentTheme.toolbarTitleFont)
                    .foregroundColor(themeManager.currentTheme.textColor)
                Spacer()
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                }
                .buttonStyle(.plain)
            }
            .padding()

            Form {
                Section {
                    Text("Only affects how the app reaches URnetwork, not your traffic.")
                        .font(themeManager.currentTheme.secondaryBodyFont)
                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                }
                Section {
                    ForEach(store.options) { option in
                        Button(action: {
                            store.select(option.code)
                        }) {
                            ConnectionRegionRow(
                                option: option,
                                selected: option.code == store.selectedCode,
                                resolvers: store.resolvers(option.code)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(!store.loaded)
                    }
                }
            }
        }
        .background(themeManager.currentTheme.backgroundColor.ignoresSafeArea())
    }
}

private struct ConnectionRegionRow: View {

    @EnvironmentObject var themeManager: ThemeManager
    let option: ConnectionRegionOption
    let selected: Bool
    let resolvers: ConnectionRegionResolvers

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(option.name)
                    .foregroundColor(themeManager.currentTheme.textColor)
                if resolvers.usesDefaults {
                    Text("Default resolvers")
                        .font(themeManager.currentTheme.secondaryBodyFont)
                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                } else {
                    if !resolvers.encrypted.isEmpty {
                        Text("Encrypted resolvers")
                            .font(themeManager.currentTheme.secondaryBodyFont)
                            .foregroundColor(themeManager.currentTheme.textMutedColor)
                        Text(verbatim: resolvers.encrypted.joined(separator: "\n"))
                            .font(.caption.monospaced())
                            .foregroundColor(themeManager.currentTheme.textMutedColor)
                    }
                    if !resolvers.plainFallback.isEmpty {
                        Text("Unencrypted fallback (URnetwork names only)")
                            .font(themeManager.currentTheme.secondaryBodyFont)
                            .foregroundColor(themeManager.currentTheme.textMutedColor)
                        Text(verbatim: resolvers.plainFallback.joined(separator: "\n"))
                            .font(.caption.monospaced())
                            .foregroundColor(themeManager.currentTheme.textMutedColor)
                    }
                }
            }
            Spacer()
            if selected {
                Image(systemName: "checkmark")
                    .foregroundColor(.urGreen)
            }
        }
        .contentShape(Rectangle())
    }
}

/// The sheet modifier both controls use.
private struct ConnectionRegionSheetModifier: ViewModifier {
    @EnvironmentObject var themeManager: ThemeManager
    @Binding var isPresented: Bool
    let store: ConnectionRegionStore

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented) {
            ConnectionRegionPickerSheet(store: store, dismiss: { isPresented = false })
                .environmentObject(themeManager)
                #if os(macOS)
                .frame(minWidth: 420, minHeight: 480)
                #endif
        }
    }
}

/**
 * The login screen's optional "Connecting from: <region> ▾" control, and the
 * can't-reach prompt when an api call could not reach URnetwork.
 */
struct ConnectionRegionLoginControl: View {

    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var deviceManager: DeviceManager
    @ObservedObject var prompt: CantReachUrnetworkPrompt = .shared
    @StateObject private var store = ConnectionRegionStore()
    @State private var presentPicker = false
    let enabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if prompt.visible {
                CantReachUrnetworkBanner(open: openPicker, dismiss: prompt.dismiss)
            }
            Button(action: openPicker) {
                HStack(spacing: 4) {
                    Text("Connecting from")
                    Text(verbatim: ":")
                    Text(verbatim: store.selectedName)
                    Image(systemName: "chevron.down")
                        .font(.caption)
                }
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(themeManager.currentTheme.textMutedColor)
            }
            .buttonStyle(.plain)
            .disabled(!enabled || deviceManager.networkSpace == nil)
        }
        .onAppear {
            store.setup(deviceManager.networkSpace)
        }
        .onChange(of: deviceManager.networkSpace) { networkSpace in
            store.setup(networkSpace)
        }
        .modifier(ConnectionRegionSheetModifier(isPresented: $presentPicker, store: store))
    }

    private func openPicker() {
        prompt.dismiss()
        store.setup(deviceManager.networkSpace)
        presentPicker = true
    }
}

/// "Can't reach URnetwork — choose where you're connecting from".
struct CantReachUrnetworkBanner: View {

    @EnvironmentObject var themeManager: ThemeManager
    let open: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            Button(action: open) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                    Text("Can't reach URnetwork — choose where you're connecting from")
                        .multilineTextAlignment(.leading)
                }
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(themeManager.currentTheme.textColor)
            }
            .buttonStyle(.plain)
            Spacer()
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .foregroundColor(themeManager.currentTheme.textMutedColor)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(themeManager.currentTheme.tintedBackgroundBase)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// The signed-in app's can't-reach prompt, shown over the main view.
struct CantReachUrnetworkOverlay: View {

    @EnvironmentObject var deviceManager: DeviceManager
    @ObservedObject var prompt: CantReachUrnetworkPrompt = .shared
    @StateObject private var store = ConnectionRegionStore()
    @State private var presentPicker = false

    var body: some View {
        VStack {
            if prompt.visible {
                CantReachUrnetworkBanner(
                    open: {
                        prompt.dismiss()
                        store.setup(deviceManager.networkSpace)
                        presentPicker = true
                    },
                    dismiss: prompt.dismiss
                )
                .padding()
            }
            Spacer()
        }
        .modifier(ConnectionRegionSheetModifier(isPresented: $presentPicker, store: store))
    }
}

/// The DNS settings' "Connection region" section.
struct ConnectionRegionSettingsSection: View {

    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var deviceManager: DeviceManager
    @StateObject private var store = ConnectionRegionStore()
    @State private var presentPicker = false

    var body: some View {
        Section {
            Button(action: {
                store.setup(deviceManager.networkSpace)
                presentPicker = true
            }) {
                HStack {
                    Text("Connection region")
                        .foregroundColor(themeManager.currentTheme.textColor)
                    Spacer()
                    Text(verbatim: store.selectedName)
                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(deviceManager.networkSpace == nil)
        } header: {
            Text("Connection region")
        } footer: {
            Text("Only affects how the app reaches URnetwork, not your traffic.")
        }
        .onAppear {
            store.setup(deviceManager.networkSpace)
        }
        .modifier(ConnectionRegionSheetModifier(isPresented: $presentPicker, store: store))
    }
}
