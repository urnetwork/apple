//
//  SelectedProvider.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2025/02/12.
//

import SwiftUI
import URnetworkSdk

struct SelectedProvider: View {

    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var networkPeersStore: NetworkPeersStore
    // the favorites the star keeps the location in
    @EnvironmentObject var connectViewModel: ConnectViewModel

    let selectedProvider: SdkConnectLocation?
    // the selected location's current provider count (selectedProviderCount)
    let providerCount: Int
    let openSelectProvider: () -> Void

    /**
     * The label for a selected location. For a network-device location we prefer the LIVE
     * peer's display name so the drawer matches the peer list exactly — `location.name` is a
     * snapshot captured at connect time and can be a stale client id if the device name loaded
     * afterward.
     */
    private func label(for location: SdkConnectLocation) -> String {
        if let clientId = location.connectLocationId?.clientId?.idStr,
            let peer = networkPeersStore.connectedProvidePeers.first(where: { $0.clientId.idStr == clientId }) {
            return peer.displayName
        }
        // the location list's name for it: a country in the app's language
        return locationDisplayName(location)
    }

    var body: some View {
        HStack {

            if let selectedProvider = selectedProvider, selectedProvider.connectLocationId?.bestAvailable != true {

                Image("ur.symbols.tab.connect")
                    .renderingMode(.template)
                    .resizable()
                    .frame(width: 32, height: 32)
                    .foregroundColor(getProviderColor(selectedProvider))

                Spacer().frame(width: 16)

                VStack(alignment: .leading) {
                    Text(label(for: selectedProvider))
                        .font(themeManager.currentTheme.bodyFont)
                        .foregroundColor(themeManager.currentTheme.textColor)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if providerCount > 0 {

                        HStack(spacing: 0) {

                            // real plural rules live in Localizable.xcstrings ("%d providers")
                            Text("\(providerCount) providers")
                                .font(themeManager.currentTheme.secondaryBodyFont)
                                .foregroundColor(themeManager.currentTheme.textMutedColor)

                            // todo - unstable warning

                        }

                    }

                }
            } else {

                Image("ur.symbols.tab.connect")
                    .renderingMode(.template)
                    .resizable()
                    .frame(width: 32, height: 32)
                    .foregroundColor(.urCoral)

                Spacer().frame(width: 16)

                VStack(alignment: .leading) {
                    Text("Best available provider")
                        .font(themeManager.currentTheme.bodyFont)
                        .foregroundColor(themeManager.currentTheme.textColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

            }

            Spacer()

            // keeps the location, or the exit stayed on, in the location
            // list's Favorites; never the best available provider
            if let selectedProvider, SdkCanFavoriteLocation(selectedProvider) {
                favoriteButton(selectedProvider)
            }

            Button(action: openSelectProvider) {
                Text("Change")
                    .font(themeManager.currentTheme.secondaryBodyFont)
            }

        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            openSelectProvider()
        }

    }

    /// The star, filled while the location is a favorite. Its own tap, not
    /// the row's, which opens the location list.
    private func favoriteButton(_ location: SdkConnectLocation) -> some View {
        let isFavorite = connectViewModel.isFavoriteLocation(location)
        let label = isFavorite ? Text("Remove from favorites") : Text("Add to favorites")
        return Button {
            connectViewModel.toggleFavoriteLocation(location)
        } label: {
            Image(systemName: isFavorite ? "star.fill" : "star")
                .foregroundColor(isFavorite ? Color.urYellow : themeManager.currentTheme.textMutedColor)
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

#Preview {
    SelectedProvider(
        selectedProvider: nil,
        providerCount: 0,
        openSelectProvider: {}
    )
    .environmentObject(NetworkPeersStore())
}
