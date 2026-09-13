//
//  ExtenderPanel.swift
//  URnetwork
//

import SwiftUI
import URnetworkSdk

/**
 * The extender panel of the connect drawer (EXTENDER.md K4), under the ip
 * family histogram.
 *
 * Left to right: one hollow ring per extender carrying a live connection right
 * now, in that address's color (K3); the count as "N of M", where N is those
 * active addresses and M is every usable directory entry; then the gossip
 * network's status dot — green connected, yellow connecting, red disconnected
 * — with its state and the rate of records and revocations applied in the
 * trailing minute. Tapping does nothing: there is no details panel yet.
 *
 * Its own view with its own status subscription, like `IpFamilyHistogram`, so
 * the once-a-second status publish re-renders this row alone rather than the
 * card's transfer charts.
 */
struct ExtenderPanel: View {

    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var deviceManager: DeviceManager

    @StateObject private var store = ExtenderStatusStore()

    // the app's general tween, matching the transport bar and the histogram
    private let tweenDuration: Double = 1.0

    /// the hollow ring of one active extender
    private let ringSize: CGFloat = 10
    /// the gossip status dot, the same 6pt as the dns status rows
    private let statusDotSize: CGFloat = 6

    var body: some View {
        let status = store.status
        let theme = themeManager.currentTheme

        VStack(alignment: .leading, spacing: 6) {

            Text("Extenders")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.textMutedColor)

            HStack(alignment: .center, spacing: 8) {

                // one hollow ring per extender with a live connection
                HStack(spacing: 3) {
                    ForEach(Array(status.activeColorHexes.enumerated()), id: \.offset) { _, colorHex in
                        Circle()
                            .strokeBorder(Color(hex: colorHex), lineWidth: extenderRingStrokeWidth)
                            .frame(width: ringSize, height: ringSize)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Active extenders"))
                .animation(.easeInOut(duration: tweenDuration), value: status.activeColorHexes)

                Text(verbatim: extenderPanelCountText(
                    activeCount: status.activeCount,
                    reserveCount: status.reserveCount
                ))
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.textColor)

                Spacer(minLength: 8)

                // the gossip network: the dot, its state, and the event rate
                HStack(spacing: 6) {

                    Circle()
                        .fill(status.gossipState.color)
                        .frame(width: statusDotSize, height: statusDotSize)

                    Text(status.gossipState.label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.textColor)

                    Text(verbatim: extenderEventRateText(status.eventCountLastMinute))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.textMutedColor)

                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text("Gossip network"))
                .animation(.easeInOut(duration: tweenDuration), value: status.gossipState)

            }
            .frame(maxWidth: .infinity, alignment: .leading)

        }
        .onAppear {
            attach()
        }
        // the connect drawer is mounted before the device attaches, and the
        // device is replaced on a reconnect: follow it rather than sampling it
        // once
        .onChange(of: deviceManager.device.map(ObjectIdentifier.init)) { _ in
            attach()
        }
        .onDisappear {
            store.reset()
        }
    }

    private func attach() {
        if let device = deviceManager.device {
            store.setup(device)
        } else {
            store.reset()
        }
    }
}

// MARK: - the panel's text
//
// Free functions rather than view state, so the unit tests exercise which
// number lands in which position without standing up a view.

/// The panel's "N of M": the extenders carrying a live connection now, of
/// every usable directory entry (K4).
func extenderPanelCountText(activeCount: Int, reserveCount: Int) -> String {
    String(localized: "\(activeCount) of \(reserveCount)")
}

/// The records and revocations applied from the feed or the mesh in the
/// trailing minute. Real plural rules live in Localizable.xcstrings; never
/// inflect in the interpolation.
func extenderEventRateText(_ eventCountLastMinute: Int) -> String {
    String(localized: "\(eventCountLastMinute) events/min")
}
