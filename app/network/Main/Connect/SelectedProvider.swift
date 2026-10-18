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
        return location.name
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
}

#Preview {
    SelectedProvider(
        selectedProvider: nil,
        providerCount: 0,
        openSelectProvider: {}
    )
    .environmentObject(NetworkPeersStore())
}
