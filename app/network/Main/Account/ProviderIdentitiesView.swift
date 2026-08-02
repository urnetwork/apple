//
//  ProviderIdentitiesView.swift
//  URnetwork
//
//  Created by Brien Colwell on 7/21/26.
//

import SwiftUI
import URnetworkSdk

/**
 * Provider Identities: a live list with one row per provider with an
 * established, identity-verified e2e session. Each row shows the provider's
 * identity key identicon, its canonical hash and its client id; tapping the
 * identicon opens the identity details sheet for that peer (the same sheet
 * as the panel's own identicon), tapping the hash copies the full hash,
 * tapping the client id copies the client id.
 */
struct ProviderIdentitiesView: View {

    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var deviceManager: DeviceManager

    @StateObject private var store = PostQuantumIdentityStore()

    // the peer whose identity details sheet is open, nil for none
    @State private var presentingRow: ProviderIdentityRow? = nil

    var body: some View {

        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(store.providerIdentities) { row in
                    VStack(spacing: 0) {
                        ProviderIdentityRowView(
                            row: row,
                            onIdenticonTap: {
                                presentingRow = row
                            }
                        )
                        Divider()
                    }
                    .transition(.opacity)
                }
            }
            .padding(.horizontal)
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if let device = deviceManager.device {
                store.setup(device)
            }
        }
        .onDisappear {
            store.reset()
        }
        // the identity details sheet for a tapped peer identicon — the same
        // sheet the panel opens for this device's own identicon
        .sheet(item: $presentingRow) { row in
            PostQuantumIdentityShareSheet(row: row)
        }

    }
}

struct ProviderIdentityRowView: View {

    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var snackbarManager: UrSnackbarManager

    let row: ProviderIdentityRow
    let onIdenticonTap: () -> Void

    var body: some View {

        HStack(alignment: .center, spacing: 16) {

            // tap opens the identity details sheet for this peer
            IdenticonView(
                image: row.identicon,
                size: PostQuantumIdentityStore.rowIdenticonSize
            )
            .contentShape(Rectangle())
            .onTapGesture {
                onIdenticonTap()
            }

            VStack(alignment: .leading, spacing: 4) {

                // the identity key hash, tap to copy the full hash
                Text(formatIdentityKeyHashForDisplay(row.publicKeyHash))
                    .font(.system(size: 13, weight: .medium).monospaced())
                    .foregroundColor(themeManager.currentTheme.textColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        copy(row.publicKeyHash, message: String(localized: "Identity key hash copied"))
                    }

                // the client id, tap to copy
                Text(row.clientId)
                    .font(.system(size: 11).monospaced())
                    .foregroundColor(themeManager.currentTheme.textFaintColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        copy(row.clientId, message: String(localized: "Client ID copied"))
                    }

            }

        }
        .padding(.vertical, 12)

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
}
