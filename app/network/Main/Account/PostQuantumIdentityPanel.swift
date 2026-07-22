//
//  PostQuantumIdentityPanel.swift
//  URnetwork
//
//  Created by Brien Colwell on 7/21/26.
//

import SwiftUI
import URnetworkSdk

/**
 * The Post Quantum Identity (PQI) panel in the account tab: a left-aligned
 * column — the title, this device's own identicon at 2x row size, its key
 * hash and client id (each tap-copies), the live deck of providers with an
 * identity-verified e2e session (tap opens the provider identities list),
 * and the explanation footer. The panel and the deck row are always
 * visible -- at zero qualifying peers the deck shows a "0 peers" status and
 * keeps its height.
 */
struct PostQuantumIdentityPanel: View {

    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var deviceManager: DeviceManager
    @EnvironmentObject var snackbarManager: UrSnackbarManager

    let navigate: (AccountNavigationPath) -> Void

    @StateObject private var store = PostQuantumIdentityStore()

    @State private var isPresentedShareSheet = false

    // at most this many provider identicons in the deck; the peer count
    // label carries the total
    private static let maxDeckIdenticons = 5
    // how far each deck identicon tucks under the previous one
    private static let deckOverlap: CGFloat = 10

    var body: some View {

        VStack(alignment: .leading, spacing: 0) {

            HStack {
                Text("Post Quantum Identity")
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(themeManager.currentTheme.textMutedColor)
                Spacer()
            }

            Spacer().frame(height: 12)

            // this device's own identity: the large identicon, then the key
            // hash and client id, each tap to copy
            if let ownRow = store.ownIdentityRow {

                // tap opens the share dialog (screenshot-friendly identicon
                // + hash + client id, with a share affordance)
                IdenticonView(
                    image: ownRow.identicon,
                    size: PostQuantumIdentityStore.panelIdenticonSize
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    isPresentedShareSheet = true
                }

                Spacer().frame(height: 12)

                Text(formatIdentityKeyHashForDisplay(ownRow.publicKeyHash))
                    .font(.system(size: 13, weight: .medium).monospaced())
                    .foregroundColor(themeManager.currentTheme.textColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        copy(ownRow.publicKeyHash, message: String(localized: "Identity key hash copied"))
                    }

                Spacer().frame(height: 4)

                Text(ownRow.clientId)
                    .font(.system(size: 11).monospaced())
                    .foregroundColor(themeManager.currentTheme.textFaintColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        copy(ownRow.clientId, message: String(localized: "Client ID copied"))
                    }

                Spacer().frame(height: 12)

            }

            // the connected peer identity deck with the peer count: always
            // visible (a "0 peers" status when none), tap for details
            providerDeck
            Spacer().frame(height: 12)

            Text("Your identity key is stored locally on this device. If any peer's key appears different than their locally stored key, it means the network operator cannot be trusted.")
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(themeManager.currentTheme.textMutedColor)
                .fixedSize(horizontal: false, vertical: true)

        }
        .onAppear {
            if let device = deviceManager.device {
                store.setup(device)
            }
        }
        .onDisappear {
            store.reset()
        }
        .sheet(isPresented: $isPresentedShareSheet) {
            if let ownRow = store.ownIdentityRow {
                PostQuantumIdentityShareSheet(row: ownRow)
            }
        }

    }

    private func copy(_ value: String, message: String) {
        #if os(iOS)
        UIPasteboard.general.string = value
        #elseif os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
        #endif
        snackbarManager.showSnackbar(message: message)
    }

    private var providerDeck: some View {

        let rows = store.providerIdentities
        let visible = Array(rows.prefix(Self.maxDeckIdenticons))

        return Button(action: {
            navigate(.providerIdentities)
        }) {
            HStack(spacing: 8) {
                if !visible.isEmpty {
                    HStack(spacing: -Self.deckOverlap) {
                        ForEach(visible) { row in
                            IdenticonView(
                                image: row.identiconSmall,
                                size: PostQuantumIdentityStore.deckIdenticonSize
                            )
                            // a ring in the card background color separates the
                            // overlapped identicons
                            .overlay(
                                RoundedRectangle(cornerRadius: PostQuantumIdentityStore.deckIdenticonSize / 6)
                                    .stroke(themeManager.currentTheme.tintedBackgroundBase, lineWidth: 2)
                            )
                        }
                    }
                }

                // the peer count indicator, always shown; the total covers
                // any identicons beyond the visible deck. printf-style key
                // shared with every platform (see peer_count_other)
                Text(rows.count == 1 ? String(localized: "1 peer") : String(format: String(localized: "%d peers"), rows.count))
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(themeManager.currentTheme.textMutedColor)

                Spacer(minLength: 0)
            }
            // reserve the stack height even at zero peers
            .frame(minHeight: PostQuantumIdentityStore.deckIdenticonSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

    }

}
