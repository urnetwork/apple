//
//  SessionsView.swift
//  URnetwork
//
//  Account > Sessions (server/session/REVOKE-UI-FINAL.md): every signed-in
//  session of the account, this app's first, each signed out after a
//  confirmation. iOS swipes a row left to reveal Sign out and pulls to
//  refresh; macOS has a trailing Sign out button, a context menu and a
//  toolbar refresh. The session ID is copied from the row's context menu
//  (a long press on iOS). SessionsStore drives the SDK controller.
//

import SwiftUI
import URnetworkSdk

struct SessionsView: View {

    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var snackbarManager: UrSnackbarManager
    @Environment(\.presentationActive) private var presentationActive

    @StateObject private var store: SessionsStore

    init(api: SdkApi) {
        _store = StateObject(wrappedValue: SessionsStore(owner: api))
    }

    var body: some View {
        // relative times move on while the screen shows; the controller's
        // own polls refresh the data
        TimelineView(.periodic(from: .now, by: 30)) { context in
            sessionsList(now: context.date)
        }
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
                    .disabled(store.snapshot.refreshing || store.snapshot.loading)
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
                Text("Sign out")
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
    }

    private func sessionsList(now: Date) -> some View {
        let snapshot = store.snapshot
        return List {
            switch snapshot.content {
            case .loading:
                stateRow {
                    ProgressView()
                }
            case .loadFailed:
                stateRow {
                    VStack(spacing: 12) {
                        Text("Couldn't load sessions.")
                            .font(themeManager.currentTheme.bodyFont)
                            .foregroundColor(themeManager.currentTheme.textMutedColor)
                            .multilineTextAlignment(.center)
                        Button(action: {
                            store.refresh()
                        }) {
                            Text("Try again")
                        }
                    }
                }
            case .unsupported:
                stateRow {
                    Text("Sessions aren't available yet.")
                        .font(themeManager.currentTheme.bodyFont)
                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                        .multilineTextAlignment(.center)
                }
            case .empty:
                refreshFailedNotice(snapshot)
                stateRow {
                    Text("No active sessions")
                        .font(themeManager.currentTheme.bodyFont)
                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                }
                notes(snapshot)
            case .list:
                refreshFailedNotice(snapshot)
                Section {
                    ForEach(snapshot.rows(now: now, format: SessionTimeFormat())) { row in
                        sessionRow(row)
                    }
                }
                if snapshot.showsSignOutOthers {
                    Section {
                        signOutOthersButton(signingOut: snapshot.signingOutOthers)
                    }
                }
                notes(snapshot)
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

    @ViewBuilder
    private func refreshFailedNotice(_ snapshot: SessionsSnapshot) -> some View {
        if snapshot.refreshFailed {
            Section {
                Label {
                    Text("Couldn't refresh. Showing the last list.")
                        .font(themeManager.currentTheme.secondaryBodyFont)
                        .foregroundColor(themeManager.currentTheme.textColor)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                }
            }
        }
    }

    private func notes(_ snapshot: SessionsSnapshot) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("Last used is the most recent sign-in activity the server saw. It can lag a few minutes, and the location is approximate.")
                if snapshot.legacyCoveragePartial {
                    Text("Sign-ins from older app versions appear here once they renew. To end every sign-in, change your sign-in details.")
                }
            }
            .font(themeManager.currentTheme.secondaryBodyFont)
            .foregroundColor(themeManager.currentTheme.textMutedColor)
            .listRowBackground(Color.clear)
        }
    }

    private func signOutOthersButton(signingOut: Bool) -> some View {
        Button(action: {
            store.requestSignOutOthers()
        }) {
            HStack(spacing: 8) {
                if signingOut {
                    ProgressView()
                        .controlSize(.small)
                    Text("Signing out…")
                } else {
                    Text("Sign out all other sessions")
                }
                Spacer(minLength: 0)
            }
            .font(themeManager.currentTheme.bodyFont)
            .foregroundColor(signingOut ? themeManager.currentTheme.textMutedColor : themeManager.currentTheme.dangerColor)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(signingOut)
    }

    private func sessionRow(_ row: SessionRowPresentation) -> some View {
        SessionRowView(
            row: row,
            signOut: {
                store.requestSignOut(sessionId: row.id)
            },
            copySessionId: {
                copySessionId(row.id)
            }
        )
        .contextMenu {
            Button(action: {
                copySessionId(row.id)
            }) {
                Label("Copy session ID", systemImage: "doc.on.doc")
            }
            #if os(macOS)
            if !row.signingOut {
                Button(role: .destructive, action: {
                    store.requestSignOut(sessionId: row.id)
                }) {
                    Text("Sign out")
                }
            }
            #endif
        }
        #if os(iOS)
        // not role: .destructive, which has the list delete the row before
        // the sign-out is confirmed; while it signs out there is no control.
        // VoiceOver lists it as the row's "Sign out <device>" action
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !row.signingOut {
                Button(action: {
                    store.requestSignOut(sessionId: row.id)
                }) {
                    Text("Sign out")
                }
                .tint(themeManager.currentTheme.dangerColor)
                .accessibilityLabel(Text(verbatim: row.signOutActionName))
            }
        }
        #endif
        .listRowBackground(themeManager.currentTheme.tintedBackgroundBase)
    }

    /// The full ID, though the row shows 8 characters.
    private func copySessionId(_ sessionId: String) {
        #if os(iOS)
        UIPasteboard.general.string = sessionId
        #elseif os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(sessionId, forType: .string)
        #endif
        snackbarManager.showSnackbar(message: String(localized: "Copied!"))
    }
}

/// One session: the country circle with the device logo, then the device and
/// version (with This session on this app's row), the place and last use, and
/// the sign-in date, method and short ID. Every relative time and date reads
/// as the full date and time to a screen reader.
private struct SessionRowView: View {

    @EnvironmentObject var themeManager: ThemeManager

    let row: SessionRowPresentation
    let signOut: () -> Void
    let copySessionId: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            HStack(alignment: .center, spacing: 16) {
                SessionDeviceCircle(colorHex: row.colorHex, icon: row.icon)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: row.title)
                            .font(themeManager.currentTheme.bodyFont)
                            .foregroundColor(themeManager.currentTheme.textColor)
                        if row.isCurrent {
                            Text("This session")
                                .font(themeManager.currentTheme.secondaryBodyFont)
                                .foregroundColor(themeManager.currentTheme.textColor)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .overlay(
                                    Capsule()
                                        .stroke(themeManager.currentTheme.borderEmphasisColor, lineWidth: 1)
                                )
                                .fixedSize()
                        }
                    }

                    Text(verbatim: row.lastUse)
                        .font(themeManager.currentTheme.secondaryBodyFont)
                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                        .accessibilityLabel(Text(verbatim: row.lastUseAccessibilityLabel))

                    Text(verbatim: row.signIn)
                        .font(themeManager.currentTheme.secondaryBodyFont)
                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                        .accessibilityLabel(Text(verbatim: row.signInAccessibilityLabel))

                    if row.signingOut {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Signing out…")
                        }
                        .font(themeManager.currentTheme.secondaryBodyFont)
                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                    } else if row.signOutFailed {
                        Text("Couldn't sign out this session. Try again.")
                            .font(themeManager.currentTheme.secondaryBodyFont)
                            .foregroundColor(themeManager.currentTheme.dangerColor)
                    }
                }

                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAction(named: Text("Copy session ID"), copySessionId)
            #if os(macOS)
            // iOS has it from the swipe action
            .accessibilityAction(named: Text(verbatim: row.signOutActionName)) {
                if !row.signingOut {
                    signOut()
                }
            }
            #endif

            #if os(macOS)
            Button(action: signOut) {
                Text("Sign out")
            }
            .disabled(row.signingOut)
            .accessibilityLabel(Text(verbatim: row.signOutActionName))
            #endif
        }
        .padding(.vertical, 8)
    }
}

/// The session's country color with its device logo in white, at about half
/// the circle (40 pt on iOS, 30 pt on macOS, as ProviderColorCircle).
private struct SessionDeviceCircle: View {

    let colorHex: String
    let icon: SessionDeviceIcon

    var body: some View {
        ProviderColorCircle(color: Color(hex: colorHex))
            .overlay(
                Image(icon.assetName)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .foregroundColor(.white)
                    .scaleEffect(0.5)
            )
            .accessibilityHidden(true)
    }
}
