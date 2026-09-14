//
//  ExtenderStatsSection.swift
//  URnetwork
//
//  Extender statistics: the traffic the provider extender role relays for
//  people whose access to the network is blocked (EXTENDER.md O4, O8).
//

import SwiftUI

/// The extender statistics section of the provider card, directly above the
/// provider statistics. Shown only while `extenderStatsSectionVisible` holds,
/// with no placeholder otherwise: the Extender row under the provide mode row
/// explains every other state. Not a tap target, since there are no extender
/// contracts.
struct ExtenderStatsSection: View {

    @EnvironmentObject var throughputStore: ThroughputStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            HStack {
                UrLabel(text: "Extender statistics")
                Spacer()
            }

            Spacer().frame(height: 8)

            Self.chart(
                points: throughputStore.extenderPoints,
                window: throughputStore.windowDuration
            )
        }
    }

    /// The transfer chart of the extender series (O8), in the Remote route
    /// where the series carries its sample: above the axis the bytes and reads
    /// moving back toward clients (egress), below it those moving toward the
    /// operator (ingress). Bytes in the H1 transport blue, and reads rather
    /// than packets in the count series pink, at the default height.
    static func chart(points: [ThroughputPoint], window: TimeInterval) -> TransferChart {
        TransferChart(
            points: points,
            route: .remote,
            title: "Extender",
            window: window,
            byteColor: .urLightBlue,
            packetColor: .urPink,
            countUnit: .reads
        )
    }
}

/// Whether the extender statistics section shows (O4, O8): while the provider
/// statistics show, which is `ProviderStatsSection`'s own gate (the provide
/// control mode is not never and the device reports provider stats), and the
/// role runs, which is the pushed status's `enabled`. Never the throughput
/// tick or the point count: the throughput listener is silent when the role
/// stops inside an idle window, and the series holds at zero after it stops.
func extenderStatsSectionVisible(
    provideControlMode: ProvideControlMode,
    hasProviderStats: Bool,
    extenderRunning: Bool
) -> Bool {
    provideControlMode != .Never && hasProviderStats && extenderRunning
}
