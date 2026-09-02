//
//  ProviderGlobeWidget.swift
//  URnetworkWidgets
//
//  The provider details globe as a widget: the tunnel's connected providers
//  plotted on the same orthographic globe the app draws, turned to face
//  their centroid, with the provider list beside or below it. Providers
//  join and leave as the tunnel's window changes; the tunnel extension
//  rewrites the snapshot and asks for a reload each time, and the widget
//  re-renders from the snapshot.
//

import SwiftUI
import WidgetKit

struct ProviderGlobeWidget: Widget {

    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: WidgetKinds.providerGlobe,
            provider: SnapshotTimelineProvider()
        ) { entry in
            ProviderGlobeView(entry: entry)
                .containerBackground(for: .widget) {
                    WidgetTheme.background
                }
        }
        .configurationDisplayName("Providers")
        .description("Your connected providers on the globe.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct ProviderGlobeView: View {

    @Environment(\.widgetFamily) private var family

    let entry: SnapshotEntry

    private var providers: [WidgetProviderSnapshot] {
        entry.showsTunnelData ? entry.tunnel.providers : []
    }

    var body: some View {
        switch family {
        case .systemSmall:
            ZStack(alignment: .bottom) {
                GlobeSnapshotView(providers: providers)
                countBadge
            }
        case .systemLarge:
            VStack(spacing: 10) {
                GlobeSnapshotView(providers: providers)
                    .frame(maxWidth: .infinity)
                    .frame(height: 180)
                list(maximum: 6)
                Spacer(minLength: 0)
            }
        default:
            HStack(spacing: 12) {
                GlobeSnapshotView(providers: providers)
                    .aspectRatio(1, contentMode: .fit)
                list(maximum: 4)
            }
        }
    }

    private var countBadge: some View {
        Text(providers.isEmpty ? "No providers" : "\(providers.count) providers")
            .font(WidgetTheme.caption)
            .foregroundStyle(WidgetTheme.textMuted)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(WidgetTheme.card, in: Capsule())
    }

    @ViewBuilder
    private func list(maximum: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Providers")
                    .font(WidgetTheme.title)
                    .foregroundStyle(WidgetTheme.text)
                    .widgetAccentable()
                Spacer()
                if !providers.isEmpty {
                    Text("\(providers.count)")
                        .font(WidgetTheme.label)
                        .foregroundStyle(WidgetTheme.textMuted)
                }
            }
            if providers.isEmpty {
                Text(emptyMessage)
                    .font(WidgetTheme.caption)
                    .foregroundStyle(WidgetTheme.textFaint)
            } else {
                ForEach(providers.prefix(maximum)) { provider in
                    ProviderRow(provider: provider, now: entry.date)
                }
                if maximum < providers.count {
                    Text("+\(providers.count - maximum) more")
                        .font(WidgetTheme.caption)
                        .foregroundStyle(WidgetTheme.textFaint)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var emptyMessage: LocalizedStringKey {
        if !entry.isConfigured {
            return "Open URnetwork to set up"
        }
        if !entry.isOn {
            return "Provider details are unavailable until connected"
        }
        return "No providers connected"
    }
}

struct ProviderRow: View {

    let provider: WidgetProviderSnapshot
    /// The timeline entry's date: the duration is formatted for it, so it
    /// advances with each entry (every five minutes) rather than ticking.
    let now: Date

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color(hexString: provider.colorHex))
                .frame(width: 8, height: 8)
                .widgetAccentable()
            // the place takes whatever is left and is the only thing that
            // truncates
            Text(place)
                .font(WidgetTheme.body)
                .foregroundStyle(WidgetTheme.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            // the app's compact duration ("3h 24m"), formatted per entry. Not
            // a relative-time Text: that reserves the width of its widest
            // possible value, which either staggered the right edge or, given
            // priority, left the place no room at all
            Text(providerDurationLabel(sinceMillis: provider.connectedSinceMillis, now: now))
                .font(WidgetTheme.label)
                .foregroundStyle(WidgetTheme.textMuted)
                .lineLimit(1)
                .fixedSize()
                .layoutPriority(1)
        }
    }

    /// The app's providerConnectedDurationLabel, with the same localized
    /// formats: "3h 24m", "24m", "42s".
    private func providerDurationLabel(sinceMillis: Int64, now: Date) -> String {
        guard 0 < sinceMillis else {
            return ""
        }
        let nowMillis = Int64(now.timeIntervalSince1970 * 1000)
        let elapsedSeconds = max(0, nowMillis - sinceMillis) / 1000
        let hours = elapsedSeconds / 3600
        let minutes = (elapsedSeconds % 3600) / 60
        let seconds = elapsedSeconds % 60
        if 0 < hours {
            return String(format: String(localized: "%1$lldh %2$lldm"), hours, minutes)
        }
        if 0 < minutes {
            return String(format: String(localized: "%lldm"), minutes)
        }
        return String(format: String(localized: "%llds"), seconds)
    }

    /// "City, Country", falling back through region and country, as the
    /// app's provider list labels a row.
    private var place: String {
        let parts = [provider.city, provider.region, provider.country].filter { !$0.isEmpty }
        if parts.isEmpty {
            return String(localized: "Location unknown")
        }
        if 2 < parts.count {
            return "\(parts[0]), \(parts[parts.count - 1])"
        }
        return parts.joined(separator: ", ")
    }
}
