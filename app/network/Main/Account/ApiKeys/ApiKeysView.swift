//
//  ApiKeysView.swift
//  URnetwork
//
//  Account > API keys (owner decision 2026-10-29): a short intro with the
//  API documentation link, Create API key, and the network's keys, newest
//  first, each with its name, creation date and id. Create opens a sheet
//  that takes a name and then shows the new key once, with Copy and the
//  warning that it is not shown again and gives full access to the account.
//  Every delete asks first, naming the key. iOS swipes a row left to reveal
//  Delete and pulls to refresh; macOS has a trailing Delete button, a
//  context menu and a toolbar refresh. ApiKeysStore drives the account api.
//

import SwiftUI
import URnetworkSdk

struct ApiKeysView: View {

    @EnvironmentObject var themeManager: ThemeManager
    @Environment(\.presentationActive) private var presentationActive

    @StateObject private var store: ApiKeysStore

    init(api: SdkApi) {
        _store = StateObject(wrappedValue: ApiKeysStore(client: api))
    }

    var body: some View {
        keysList
            .onAppear {
                store.setPresentationActive(presentationActive)
                store.setOnScreen(true)
            }
            .onDisappear {
                store.setOnScreen(false)
            }
            .onChange(of: presentationActive) { active in
                store.setPresentationActive(active)
            }
            #if os(macOS)
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    HStack(spacing: 8) {
                        if store.snapshot.refreshing {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Button(action: {
                            store.refresh()
                        }) {
                            Image(systemName: "arrow.clockwise")
                        }
                        .disabled(store.snapshot.loading)
                        .help("Refresh")
                        .accessibilityLabel("Refresh")
                    }
                }
            }
            #endif
            .confirmationDialog(
                store.confirmation?.title ?? "",
                isPresented: Binding(
                    get: { store.confirmation != nil },
                    set: { presented in
                        if !presented {
                            store.cancelConfirmation()
                        }
                    }
                ),
                titleVisibility: .visible,
                presenting: store.confirmation
            ) { confirmation in
                Button(role: .destructive) {
                    store.confirm(confirmation)
                } label: {
                    Text("Delete")
                }
                // Cancel is the default: Return and Escape both cancel on macOS
                Button(role: .cancel) {
                    store.cancelConfirmation()
                } label: {
                    Text("Cancel")
                }
                #if os(macOS)
                .keyboardShortcut(.defaultAction)
                #endif
            } message: { confirmation in
                Text(verbatim: confirmation.message)
            }
            // the store drops the name and the key once the sheet has closed,
            // however it closed
            .sheetOffTheFold(isPresented: $store.createSheetPresented, onDismiss: {
                store.closeCreate()
            }) {
                ApiKeyCreateSheet(store: store)
                    .environmentObject(themeManager)
            }
    }

    private var keysList: some View {
        let snapshot = store.snapshot
        return List {
            intro

            Section {
                createButton
            }

            switch snapshot.content {
            case .loading:
                stateRow {
                    ProgressView()
                }
            case .loadFailed:
                stateRow {
                    VStack(spacing: 12) {
                        Text(verbatim: ApiKeysFailure.load)
                            .font(themeManager.currentTheme.bodyFont)
                            .foregroundColor(themeManager.currentTheme.textMutedColor)
                            .multilineTextAlignment(.center)
                        Button(action: {
                            store.refresh()
                        }) {
                            Text("Retry")
                        }
                    }
                }
            case .empty:
                refreshFailedNotice(snapshot)
                stateRow {
                    Text("You don't have any API keys.")
                        .font(themeManager.currentTheme.bodyFont)
                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                        .multilineTextAlignment(.center)
                }
            case .list:
                refreshFailedNotice(snapshot)
                Section {
                    ForEach(snapshot.rows(format: SessionTimeFormat())) { row in
                        keyRow(row)
                    }
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        .refreshable {
            await store.refreshAndWait()
        }
        #elseif os(macOS)
        .listStyle(.inset)
        #endif
        .scrollContentBackground(.hidden)
        .background(themeManager.currentTheme.backgroundColor)
    }

    /// What keys are for, and the API documentation.
    private var intro: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Text("API keys let your own tools and scripts use your URnetwork account through the API. Anyone with a key has full access to your account until you delete it.")
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(themeManager.currentTheme.textMutedColor)
                    .fixedSize(horizontal: false, vertical: true)

                Link(destination: ApiKeysLinks.docs) {
                    HStack(spacing: 4) {
                        Text("How to use API keys")
                        Image(systemName: "arrow.up.right.square")
                            .accessibilityHidden(true)
                    }
                    .font(themeManager.currentTheme.bodyFont)
                }
            }
            .listRowBackground(Color.clear)
        }
    }

    private var createButton: some View {
        Button(action: {
            store.startCreate()
        }) {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .accessibilityHidden(true)
                Text("Create API key")
                Spacer(minLength: 0)
            }
            .font(themeManager.currentTheme.bodyFont)
            .foregroundColor(themeManager.currentTheme.textColor)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("acceptance.apikeys.create")
        .listRowBackground(themeManager.currentTheme.tintedBackgroundBase)
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

    /// A failed refresh over the rows it kept, with Retry.
    @ViewBuilder
    private func refreshFailedNotice(_ snapshot: ApiKeysSnapshot) -> some View {
        if snapshot.refreshFailed {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label {
                        Text(verbatim: ApiKeysFailure.load)
                            .font(themeManager.currentTheme.secondaryBodyFont)
                            .foregroundColor(themeManager.currentTheme.textColor)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundColor(themeManager.currentTheme.textMutedColor)
                    }
                    Button(action: {
                        store.refresh()
                    }) {
                        Text("Retry")
                    }
                    .font(themeManager.currentTheme.secondaryBodyFont)
                }
            }
        }
    }

    private func keyRow(_ row: ApiKeyRowPresentation) -> some View {
        ApiKeyRowView(
            row: row,
            delete: {
                store.requestDelete(keyId: row.id)
            }
        )
        #if os(macOS)
        .contextMenu {
            if !row.deleting {
                Button(role: .destructive, action: {
                    store.requestDelete(keyId: row.id)
                }) {
                    Text("Delete")
                }
            }
        }
        #endif
        #if os(iOS)
        // not role: .destructive, which has the list delete the row before
        // the delete is confirmed; while it deletes there is no control.
        // VoiceOver lists it as the row's Delete action
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !row.deleting {
                Button(action: {
                    store.requestDelete(keyId: row.id)
                }) {
                    Text("Delete")
                }
                .tint(themeManager.currentTheme.dangerColor)
            }
        }
        #endif
        .listRowBackground(themeManager.currentTheme.tintedBackgroundBase)
    }
}

/// One key: the key glyph, then the name, the creation date and the id, and
/// a failed delete under them. A date reads as the full date and time to a
/// screen reader.
private struct ApiKeyRowView: View {

    @EnvironmentObject var themeManager: ThemeManager

    let row: ApiKeyRowPresentation
    let delete: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            HStack(alignment: .center, spacing: 16) {
                Image("ur.symbols.api.key")
                    .renderingMode(.template)
                    .foregroundColor(themeManager.currentTheme.textMutedColor)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: row.name)
                        .font(themeManager.currentTheme.bodyFont)
                        .foregroundColor(themeManager.currentTheme.textColor)

                    if let created = row.created {
                        Text(verbatim: created)
                            .font(themeManager.currentTheme.secondaryBodyFont)
                            .foregroundColor(themeManager.currentTheme.textMutedColor)
                            .accessibilityLabel(Text(verbatim: row.createdAccessibilityLabel ?? created))
                    }

                    Text(verbatim: row.idLine)
                        .font(themeManager.currentTheme.secondaryBodyFont)
                        .foregroundColor(themeManager.currentTheme.textMutedColor)

                    if row.deleteFailed {
                        Text(verbatim: ApiKeysFailure.delete)
                            .font(themeManager.currentTheme.secondaryBodyFont)
                            .foregroundColor(themeManager.currentTheme.dangerColor)
                    }
                }

                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            #if os(macOS)
            // iOS has it from the swipe action
            .accessibilityAction(named: Text("Delete")) {
                if !row.deleting {
                    delete()
                }
            }
            #endif

            if row.deleting {
                ProgressView()
                    .controlSize(.small)
            } else {
                #if os(macOS)
                Button(action: delete) {
                    Text("Delete")
                }
                #endif
            }
        }
        .padding(.vertical, 8)
    }
}

/**
 * Create: the name form, then the new key, once. The key shows in full only
 * while the app is active on iOS, so the app switcher's snapshot never has
 * it; it is copied with SensitivePasteboard and never selectable, so every
 * copy is local-only and expires. While a create is in flight and while the
 * key shows, only the sheet's own buttons close it.
 */
private struct ApiKeyCreateSheet: View {

    @EnvironmentObject var themeManager: ThemeManager
    #if os(iOS)
    @Environment(\.scenePhase) private var scenePhase
    #endif

    @ObservedObject var store: ApiKeysStore

    @State private var name = ""
    // Copy key reads Copied for a moment after each copy
    @State private var copied = false
    @State private var copyCount = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch store.createStep {
                    case .naming(let failed):
                        nameForm(creating: false, failed: failed)
                    case .creating:
                        nameForm(creating: true, failed: false)
                    case .created(let created):
                        createdKey(created)
                    case nil:
                        // closing
                        EmptyView()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .background(themeManager.currentTheme.backgroundColor.ignoresSafeArea())
            .toolbar {
                if case .created = store.createStep {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(action: {
                            store.dismissCreate()
                        }) {
                            Text("Done")
                        }
                    }
                } else {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(action: {
                            store.dismissCreate()
                        }) {
                            Text("Cancel")
                        }
                        .disabled(store.createStep == .creating)
                    }
                }
            }
        }
        .interactiveDismissDisabled(!(store.createStep?.closesFreely ?? true))
        #if os(macOS)
        .frame(minWidth: 440, idealWidth: 480, minHeight: 340)
        #endif
    }

    private func create() {
        store.create(name: name)
    }

    private func nameForm(creating: Bool, failed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Create API key")
                .font(themeManager.currentTheme.titleFont)
                .foregroundColor(themeManager.currentTheme.textColor)

            UrTextField(
                text: $name,
                label: "Key name",
                placeholder: "For example, home server",
                isEnabled: !creating,
                validationState: failed ? .invalid : nil,
                onTextChange: { text in
                    // the server takes 128 characters
                    let limited = ApiKeyName.limited(text)
                    if limited != text {
                        name = limited
                    }
                },
                submitLabel: .done,
                onSubmit: create,
                disableCapitalization: true,
                accessibilityIdentifier: "acceptance.apikeys.name",
                disableAutocorrection: true
            )

            if failed {
                Text(verbatim: ApiKeysFailure.create)
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(themeManager.currentTheme.dangerColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            UrButton(
                text: "Create API key",
                action: create,
                enabled: ApiKeyName.normalized(name) != nil,
                isProcessing: creating,
                accessibilityIdentifier: "acceptance.apikeys.submit"
            )
        }
    }

    private func createdKey(_ created: ApiKeyCreatedItem) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Your new API key")
                .font(themeManager.currentTheme.titleFont)
                .foregroundColor(themeManager.currentTheme.textColor)

            Label {
                Text("Copy this key now. It won't be shown again, and anyone who has it can use your account.")
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(themeManager.currentTheme.textColor)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundColor(themeManager.currentTheme.dangerColor)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: ApiKeyLabels.name(ApiKeyItem(id: created.id, name: created.name)))
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(themeManager.currentTheme.textMutedColor)

                Text(verbatim: keyShown ? created.apiKey : String(repeating: "•", count: 24))
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(themeManager.currentTheme.textColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .privacySensitive()
                    .accessibilityIdentifier("acceptance.apikeys.key")
            }
            .padding()
            .background(themeManager.currentTheme.tintedBackgroundBase)
            .cornerRadius(8)

            UrButton(
                text: copied ? "Copied" : "Copy key",
                action: {
                    copy(created.apiKey)
                },
                style: .secondary,
                leadingSystemImage: copied ? "checkmark" : "doc.on.doc",
                accessibilityIdentifier: "acceptance.apikeys.copy"
            )
        }
    }

    /// iOS hides the key while the app is not active.
    private var keyShown: Bool {
        #if os(iOS)
        return scenePhase == .active
        #else
        return true
        #endif
    }

    private func copy(_ apiKey: String) {
        SensitivePasteboard.copy(apiKey)
        copyCount += 1
        let count = copyCount
        copied = true
        announce(String(localized: "Copied"))
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            // a later copy keeps its own moment
            if copyCount == count {
                copied = false
            }
        }
    }

    /// Tells a screen reader the key was copied.
    private func announce(_ message: String) {
        #if os(iOS)
        UIAccessibility.post(notification: .announcement, argument: message)
        #elseif os(macOS)
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
        #endif
    }
}
