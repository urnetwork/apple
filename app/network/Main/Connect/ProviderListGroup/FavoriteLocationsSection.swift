//
//  FavoriteLocationsSection.swift
//  URnetwork
//
//  The location list's Favorites: the places, collections and exits the user
//  starred on the connect screen, at the top of the list on iOS and macOS.
//

import SwiftUI
import URnetworkSdk

/// The favorites, the newest first, in the rows of the other groups
/// (ProviderListGroup); hidden while there are none. A tap connects, as any
/// row's does. A favorite exit is one member's device rather than a place, so
/// its row says it can go away (SdkIsFavoriteExit).
struct FavoriteLocationsSection: View {

    @EnvironmentObject var themeManager: ThemeManager

    let favoriteLocations: [SdkConnectLocation]
    let selectedProvider: SdkConnectLocation?
    let connect: (SdkConnectLocation) -> Void

    #if os(iOS)
    let padding: CGFloat = 16
    #elseif os(macOS)
    let padding: CGFloat = 0
    #endif

    var body: some View {

        if !favoriteLocations.isEmpty {

            Section(
                header: HStack {
                    Text("Favorites")
                        .font(themeManager.currentTheme.bodyFont)
                        .foregroundColor(themeManager.currentTheme.textColor)

                    Spacer()
                }
                    .padding(.horizontal, padding)
                    .padding(.vertical, 8)
            ) {

                ForEach(favoriteLocations, id: \.connectLocationId) { location in
                    ProviderListItemView(
                        // a country in the app's language, the kept name otherwise
                        name: locationDisplayName(location),
                        // a favorite keeps no count, so none shows
                        providerCount: location.providerCount,
                        color: getProviderColor(location),
                        isSelected: selectedProvider != nil && selectedProvider?.connectLocationId?.cmp(location.connectLocationId) == 0,
                        connect: {
                            connect(location)
                        },
                        isStable: location.stable,
                        isStrongPrivacy: location.strongPrivacy,
                        note: SdkIsFavoriteExit(location)
                            ? String(localized: "A member's device. It can go offline or leave the network at any time.")
                            : nil
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                }
            }
            .listRowBackground(Color.clear)

        }

    }

}
