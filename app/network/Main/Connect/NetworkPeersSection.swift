//
//  NetworkPeersSection.swift
//  URnetwork
//
//  Created by Brien Colwell on 7/8/26.
//

import SwiftUI
import URnetworkSdk

/**
 * Network peers pinned at the top of the available providers list.
 * Shows the connected peers with provide enabled, updating in real time.
 * Hidden while there are no peers.
 */
struct NetworkPeersSection: View {

    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var networkPeersStore: NetworkPeersStore

    let selectedProvider: SdkConnectLocation?
    let connect: (SdkConnectLocation) -> Void

    #if os(iOS)
    let padding: CGFloat = 16
    #elseif os(macOS)
    let padding: CGFloat = 0
    #endif

    var body: some View {

        if !networkPeersStore.connectedProvidePeers.isEmpty {

            Section(
                header: HStack {
                    Text("Network peers")
                        .font(themeManager.currentTheme.bodyFont)
                        .foregroundColor(themeManager.currentTheme.textColor)

                    Spacer()
                }
                .padding(.horizontal, padding)
                .padding(.vertical, 8)
            ) {

                ForEach(networkPeersStore.connectedProvidePeers) { peer in
                    NetworkPeerRow(
                        peer: peer,
                        isSelected: isSelected(peer),
                        connect: {
                            connect(peer.toConnectLocation())
                        }
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                }

            }

        }
    }

    private func isSelected(_ peer: NetworkPeerItem) -> Bool {
        guard let selectedClientId = selectedProvider?.connectLocationId?.clientId else {
            return false
        }
        return selectedClientId.idStr == peer.clientId.idStr
    }
}

struct NetworkPeerRow: View {

    @EnvironmentObject var themeManager: ThemeManager

    let peer: NetworkPeerItem
    let isSelected: Bool
    let connect: () -> Void

    #if os(iOS)
    let padding: CGFloat = 16
    #elseif os(macOS)
    let padding: CGFloat = 0
    #endif

    var body: some View {
        HStack {

            ProviderColorCircle(
                color: Color(hex: SdkGetColorHex(peer.clientId.idStr))
            )

            Spacer().frame(width: 16)

            VStack(alignment: .leading) {

                Text(peer.displayName)
                    .font(themeManager.currentTheme.bodyFont)
                    .foregroundColor(themeManager.currentTheme.textColor)

                if !peer.deviceName.isEmpty && !peer.deviceSpec.isEmpty {
                    Text(peer.deviceSpec)
                        .font(themeManager.currentTheme.secondaryBodyFont)
                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                }

            }

            Spacer()

            HStack {

                /**
                 * providing
                 */
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 13))
                    .foregroundColor(.urGreen)

                Spacer().frame(width: 16)

                Image(systemName: "checkmark")
                    .foregroundColor(isSelected ? .urElectricBlue : .clear)
                    .font(.system(size: 20))

            }

        }
        .padding(.vertical, 8)
        .padding(.horizontal, padding)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            connect()
        }
        .accessibilityIdentifier(peer.acceptanceIdentifier)
        .listRowBackground(Color.clear)
    }
}
