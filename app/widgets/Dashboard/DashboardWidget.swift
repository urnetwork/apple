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
