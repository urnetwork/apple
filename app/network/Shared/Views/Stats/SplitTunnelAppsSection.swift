//
//  SplitTunnelAppsSection.swift
//  URnetwork
//
//  macOS 15 and later: the Apps section of the split rules screen. Apps
//  picked from /Applications are stored as app rules with the site rules
//  (BlockActionsStore.addAppRule) and kept off the VPN by the split tunnel
//  system extension (SplitTunnelProxyController). Edits are gated like the
//  site rules: only against a rule list the store can vouch for.
//

#if os(macOS)

import AppKit
import SwiftUI

/// The split rules screen's Apps section: the status line, the add row and
/// the excluded apps.
@available(macOS 15.0, *)
struct SplitTunnelAppsSection: View {

    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var blockActionsStore: BlockActionsStore
    @EnvironmentObject var splitTunnelProxyController: SplitTunnelProxyController

    /// nil until the first scan of /Applications lands
    @State private var applications: [InstalledApplication]? = nil
    @State private var isPresentingPicker = false

    var body: some View {
        Section(
            header: Text("Apps")
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(themeManager.currentTheme.textMutedColor)
                .textCase(nil)
        ) {

            Text("Apps listed here bypass the VPN.")
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(themeManager.currentTheme.textMutedColor)
                .listRowBackground(Color.clear)

            statusRow

            addAppRow

            ForEach(blockActionsStore.appRules) { rule in
                SplitTunnelAppRuleRow(rule: rule, applications: applications ?? [])
                    .contextMenu {
                        Button(role: .destructive) {
                            blockActionsStore.removeRule(id: rule.id)
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                    .listRowBackground(Color.clear)
            }
            .onDelete { indexSet in
                let rules = blockActionsStore.appRules
                for index in indexSet where index < rules.count {
                    blockActionsStore.removeRule(id: rules[index].id)
                }
            }
        }
        .task {
            await scanApplications()
        }
        .sheet(isPresented: $isPresentingPicker) {
            SplitTunnelAppPickerView(applications: applications)
                .environmentObject(themeManager)
                .environmentObject(blockActionsStore)
                .frame(minWidth: 420, minHeight: 460)
        }
    }

    /// What needs the user before the excluded apps can bypass the VPN.
    @ViewBuilder
    private var statusRow: some View {
        switch splitTunnelProxyController.status {
        case .needsApproval:
            statusMessage(
                "To keep these apps off the VPN, allow the URnetwork Split Tunnel extension in System Settings.",
                action: "Open System Settings"
            ) {
                splitTunnelProxyController.openSystemSettings()
            }
        case .failed:
            statusMessage(
                "These apps can't bypass the VPN right now. Retry, and allow the proxy configuration if macOS asks.",
                action: "Retry"
            ) {
                splitTunnelProxyController.retry()
            }
        case .off, .pending, .ready, .active:
            EmptyView()
        }
    }

    /// A status line with the one action that resolves it.
    private func statusMessage(
        _ message: LocalizedStringKey,
        action: LocalizedStringKey,
        perform: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(message)
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(Color.urAmber)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: perform) {
                Text(action)
                    .font(themeManager.currentTheme.secondaryBodyFont)
            }
        }
        .listRowBackground(Color.clear)
    }

    /// Opens the picker; disabled until the store can vouch for the rule list.
    @ViewBuilder
    private var addAppRow: some View {
        Button(action: {
            isPresentingPicker = true
        }) {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                    .foregroundColor(
                        blockActionsStore.canCreateRule
                            ? .urGreen
                            : themeManager.currentTheme.textFaintColor
                    )
                Text("Add an app")
                    .font(themeManager.currentTheme.bodyFont)
                    .foregroundColor(
                        blockActionsStore.canCreateRule
                            ? themeManager.currentTheme.textColor
                            : themeManager.currentTheme.textFaintColor
                    )
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // the note under "Add a rule" says why
        .disabled(!blockActionsStore.canCreateRule)
        .listRowBackground(Color.clear)
    }

    /// Reads /Applications off the main actor (a signature read per bundle).
    private func scanApplications() async {
        let scanned = await Task.detached(priority: .userInitiated) {
            InstalledApplicationScanner.scan()
        }.value
        applications = scanned
    }
}

/// An excluded app: its icon and name when it is installed, else the
/// identifier the rule stores; routed locally like a site rule.
@available(macOS 15.0, *)
private struct SplitTunnelAppRuleRow: View {

    @EnvironmentObject var themeManager: ThemeManager

    let rule: SplitTunnelAppRule
    let applications: [InstalledApplication]

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(rule.appIds, id: \.self) { appId in
                    let application = InstalledApplicationCatalog.application(for: appId, in: applications)
                    HStack(spacing: 8) {
                        if let application {
                            Image(nsImage: InstalledApplicationScanner.icon(for: application))
                                .resizable()
                                .frame(width: 20, height: 20)
                        } else {
                            Image(systemName: "app.dashed")
                                .frame(width: 20, height: 20)
                                .foregroundColor(themeManager.currentTheme.textFaintColor)
                        }
                        Text(application?.name ?? appId)
                            .font(themeManager.currentTheme.bodyFont)
                            .foregroundColor(themeManager.currentTheme.textColor)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if rule.local {
                StateChip(text: "Local", color: .urGreen, highlighted: true)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Picks one app from /Applications to keep off the VPN.
@available(macOS 15.0, *)
struct SplitTunnelAppPickerView: View {

    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var blockActionsStore: BlockActionsStore
    @Environment(\.dismiss) private var dismiss

    /// nil while /Applications is still being read
    let applications: [InstalledApplication]?

    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            HStack {
                Text("Add an app")
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

            TextField("Search apps", text: $query)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .padding(.horizontal)
                .padding(.bottom, 8)

            List {
                if let applications {
                    let results = InstalledApplicationCatalog.search(applications, query: query)
                    if results.isEmpty {
                        Text("No apps found")
                            .font(themeManager.currentTheme.secondaryBodyFont)
                            .foregroundColor(themeManager.currentTheme.textFaintColor)
                            .listRowBackground(Color.clear)
                    } else {
                        ForEach(results) { application in
                            applicationRow(application)
                        }
                    }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)

        }
        .background(themeManager.currentTheme.backgroundColor)
    }

    /// One app: picking it excludes it and closes the sheet; an app already
    /// excluded is checked and cannot be picked again.
    private func applicationRow(_ application: InstalledApplication) -> some View {
        let excluded = SplitTunnelAppRules.isExcluded(application.identifier, in: blockActionsStore.appRules)
        return Button(action: {
            blockActionsStore.addAppRule(identifier: application.identifier)
            dismiss()
        }) {
            HStack(spacing: 10) {
                Image(nsImage: InstalledApplicationScanner.icon(for: application))
                    .resizable()
                    .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(application.name)
                        .font(themeManager.currentTheme.bodyFont)
                        .foregroundColor(themeManager.currentTheme.textColor)
                    Text(application.identifier)
                        .font(.system(size: 11))
                        .foregroundColor(themeManager.currentTheme.textFaintColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                if excluded {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.urGreen)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(excluded || !blockActionsStore.canCreateRule)
        .listRowBackground(Color.clear)
    }
}

#endif
