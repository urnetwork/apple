//
//  ManageDevicesView.swift
//  URnetwork
//
//  The device list ("Manage devices"): the network's devices and hosted
//  proxies, this device first, each other one removable after a confirmation.
//  Removing one frees its slot of the plan's devices connected at once, and
//  the sdk then adds this device again (ManageDevicesStore). Pushed from
//  Settings, and in a sheet (ManageDevicesSheet) from the client limit notice
//  and from a sign-in the limit refused.
//

import SwiftUI
import URnetworkSdk

struct ManageDevicesView: View {

    @EnvironmentObject var themeManager: ThemeManager

    @StateObject private var store: ManageDevicesStore
    /// why the list opened, above it; nil from Settings
    private let message: String?

    init(store: @escaping @autoclosure () -> ManageDevicesStore, message: String? = nil) {
        _store = StateObject(wrappedValue: store())
        self.message = message
    }

    var body: some View {
        // "Last seen" moves on while the screen shows
        TimelineView(.periodic(from: .now, by: 30)) { context in
            devicesList(now: context.date)
        }
        .onAppear {
            store.start()
        }
        #if os(macOS)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button(action: {
                    store.refresh()
                }) {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(store.state.loading)
                .help("Refresh")
                .accessibilityLabel("Refresh")
            }
        }
        #endif
        .confirmationDialog(
            "Remove this device?",
            isPresented: Binding(
                get: { store.confirmation != nil },
                set: { presented in
                    if !presented {
                        store.cancelRemove()
                    }
                }
            ),
            titleVisibility: .visible,
            presenting: store.confirmation
        ) { device in
            Button(role: .destructive) {
                store.confirmRemove(device)
            } label: {
                Text("Remove")
            }
            // Cancel is the default: Return and Escape both cancel on macOS
            Button(role: .cancel) {
                store.cancelRemove()
            } label: {
                Text("Cancel")
            }
            #if os(macOS)
            .keyboardShortcut(.defaultAction)
            #endif
        } message: { device in
            Text(verbatim: String(format: String(localized: "%@ will be signed out."), ManageDevicesLabels.title(device)))
        }
    }

    private func devicesList(now: Date) -> some View {
        let state = store.state
        return List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    if let message {
                        Text(verbatim: message)
                            .font(themeManager.currentTheme.bodyFont)
                            .foregroundColor(themeManager.currentTheme.textColor)
                    }
                    Text("Each connected device or proxy uses a slot of your plan. Remove one you no longer use to free its slot.")
                        .font(themeManager.currentTheme.secondaryBodyFont)
                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                }
                .fixedSize(horizontal: false, vertical: true)
                .listRowBackground(Color.clear)
            }

            if store.connecting {
                Section {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Connecting this device…")
                            .font(themeManager.currentTheme.bodyFont)
                            .foregroundColor(themeManager.currentTheme.textColor)
                    }
                    .accessibilityIdentifier("acceptance.manageDevices.connecting")
                }
            }

            if state.signInRequired {
                // only a new sign-in, through the app's own flow, helps
                stateRow {
                    Text("Sign in again to manage devices.")
                        .font(themeManager.currentTheme.bodyFont)
                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                        .multilineTextAlignment(.center)
                }
            } else if !state.loaded {
                if state.loadFailed && !state.loading {
                    stateRow {
                        loadFailed()
                    }
                } else {
                    stateRow {
                        ProgressView()
                    }
                }
            } else {
                if state.loadFailed && !state.loading {
                    Section {
                        loadFailed()
                    }
                }
                if state.removeFailed {
                    Section {
                        Label {
                            Text("Couldn't remove the device. Try again.")
                                .font(themeManager.currentTheme.secondaryBodyFont)
                                .foregroundColor(themeManager.currentTheme.textColor)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundColor(themeManager.currentTheme.textMutedColor)
                        }
                    }
                }
                Section {
                    ForEach(state.devices) { device in
                        deviceRow(device, removing: state.removingClientId, now: now)
                    }
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        .refreshable {
            store.refresh()
        }
        #elseif os(macOS)
        .listStyle(.inset)
        #endif
        .scrollContentBackground(.hidden)
        .background(themeManager.currentTheme.backgroundColor)
    }

    private func loadFailed() -> some View {
        VStack(spacing: 12) {
            Text("Couldn't load your devices.")
                .font(themeManager.currentTheme.bodyFont)
                .foregroundColor(themeManager.currentTheme.textMutedColor)
                .multilineTextAlignment(.center)
            Button(action: {
                store.refresh()
            }) {
                Text("Try again")
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// A state shown in place of the rows, inside the list so a pull still
    /// refreshes.
    private func stateRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack {
            Spacer(minLength: 0)
            content()
            Spacer(minLength: 0)
        }
        .padding(.vertical, 24)
        .listRowBackground(Color.clear)
    }

    private func deviceRow(_ device: ManagedDeviceItem, removing: String?, now: Date) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: device.proxy ? "network" : "laptopcomputer.and.iphone")
                .foregroundColor(themeManager.currentTheme.textMutedColor)
                .frame(width: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: ManageDevicesLabels.title(device))
                    .font(themeManager.currentTheme.bodyFont)
                    .foregroundColor(themeManager.currentTheme.textColor)
                    .lineLimit(1)
                let detail = ManageDevicesLabels.detail(device, now: now)
                if !detail.isEmpty {
                    Text(verbatim: detail)
                        .font(themeManager.currentTheme.secondaryBodyFont)
                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 0)

            if !device.thisDevice {
                if removing == device.id {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button(action: {
                        store.requestRemove(device)
                    }) {
                        Text("Remove")
                            .font(themeManager.currentTheme.secondaryBodyFont)
                            .foregroundColor(removing == nil ? themeManager.currentTheme.dangerColor : themeManager.currentTheme.textMutedColor)
                    }
                    .buttonStyle(.plain)
                    .disabled(removing != nil)
                    .accessibilityIdentifier("acceptance.manageDevices.remove")
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// The words of a row.
enum ManageDevicesLabels {

    private static let separator = " · "

    /// The device's name, else what it is.
    static func title(_ device: ManagedDeviceItem) -> String {
        if !device.name.isEmpty {
            return device.name
        }
        return device.proxy ? String(localized: "Hosted proxy") : String(localized: "Unknown device")
    }

    /// "This device · 18.5 iPhone 16 · Connected", or "Last seen 5m ago".
    static func detail(_ device: ManagedDeviceItem, now: Date, format: SessionTimeFormat = SessionTimeFormat()) -> String {
        var parts: [String] = []
        if device.thisDevice {
            parts.append(String(localized: "This device"))
        }
        if device.proxy && !device.name.isEmpty {
            parts.append(String(localized: "Hosted proxy"))
        }
        if !device.spec.isEmpty {
            parts.append(device.spec)
        }
        if device.connected {
            parts.append(String(localized: "Connected"))
        } else if 0 < device.lastSeenTime {
            let lastSeen = Date(timeIntervalSince1970: TimeInterval(device.lastSeenTime) / 1000)
            parts.append(String(format: String(localized: "Last seen %@"), format.lastUsed(lastSeen, now: now)))
        }
        return parts.joined(separator: separator)
    }
}

/// The device list in a sheet: from the client limit notice, and from a
/// sign-in the limit refused.
struct ManageDevicesSheet: View {

    @EnvironmentObject var themeManager: ThemeManager

    private let makeStore: () -> ManageDevicesStore
    private let message: String?
    private let dismiss: () -> Void

    init(store: @escaping @autoclosure () -> ManageDevicesStore, message: String? = nil, dismiss: @escaping () -> Void) {
        self.makeStore = store
        self.message = message
        self.dismiss = dismiss
    }

    var body: some View {
        NavigationStack {
            ManageDevicesView(store: makeStore(), message: message)
                .navigationTitle("Manage devices")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(action: dismiss) {
                            Text("Done")
                        }
                        .accessibilityIdentifier("acceptance.manageDevices.done")
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 520)
        #endif
    }
}
