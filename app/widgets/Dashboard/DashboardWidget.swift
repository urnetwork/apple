//
//  DashboardWidget.swift
//  URnetworkWidgets
//
//  The Home Screen dashboard: transfer balance on top, the connected location
//  with the quick connect toggle, and (large) the client and provider
//  throughput for the last hour. Medium drops the charts.
//

import SwiftUI
import WidgetKit

struct DashboardWidget: Widget {

    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: WidgetKinds.dashboard,
            provider: SnapshotTimelineProvider()
        ) { entry in
            DashboardView(entry: entry)
                .containerBackground(for: .widget) {
                    WidgetTheme.background
                }
        }
        .configurationDisplayName("URnetwork")
        .description("Transfer balance, connected location and traffic, with quick connect.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

#if DEBUG
extension SnapshotEntry {
    /// The gallery's sample while the slow internet notice shows, with the
    /// proposal's numbers (apple/DELAY.md §5.7).
    static func sampleSlow(level: Int, upDelayMillis: Int64, downDelayMillis: Int64, fallback: Bool = false) -> SnapshotEntry {
        let activity = TransportDelayAttributes.ContentState(
            level: level,
            previousLevel: level,
            upDelayMillis: upDelayMillis,
            downDelayMillis: downDelayMillis,
            upBitsPerSecond: 0,
            downBitsPerSecond: 0,
            fallback: fallback,
            recovered: false
        )
        var entry = sample(at: Date())
        entry.slowInternet = SlowInternetWidgetPill(level: level, content: SlowInternetPillContent(activity: activity))
        return entry
    }
}

#Preview("Slow", as: .systemMedium) {
    DashboardWidget()
} timeline: {
    SnapshotEntry.sampleSlow(level: 3, upDelayMillis: 800, downDelayMillis: 1900)
    SnapshotEntry.sampleSlow(level: 2, upDelayMillis: 420, downDelayMillis: 1100, fallback: true)
}

#Preview("Slow, large", as: .systemLarge) {
    DashboardWidget()
} timeline: {
    SnapshotEntry.sampleSlow(level: 4, upDelayMillis: 1300, downDelayMillis: 2900)
}
#endif
