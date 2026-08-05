//
//  ProviderLocationsView.swift
//  URnetwork
//

import SwiftUI
import URnetworkSdk

/**
 * The connected providers and where they are: a fixed globe on top and an
 * independently scrolling list below. Selection is shared between the two —
 * tapping a row spins the globe to that provider, and stepping the globe's
 * wheel moves the list selection.
 *
 * There is deliberately no device-location sync here. Core Location has no
 * injection point an app can reach on a shipping device (see
 * PROVIDERLOCATIONS.md, "Apple"), so the Android toggle has no counterpart.
 */
struct ProviderLocationsView: View {

    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var deviceManager: DeviceManager

    @StateObject private var store = ProviderLocationsStore()

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {

                // the globe is fixed at the top and the list scrolls under it;
                // its height is set explicitly because two flexible siblings in
                // a VStack would otherwise negotiate the split between them
                ProviderGlobeView(
                    rows: store.rows,
                    selectedClientId: $store.selectedClientId
                )
                .frame(height: providerGlobeHeight(in: geometry.size))

                if !store.providersAvailable {

                    // The window state lives in the network extension's device,
                    // which only runs while the tunnel is up. With the RPC down
                    // there is nothing real to report, and an empty list would
                    // present a stale zero as fact.
                    unavailableState

                } else if store.rows.isEmpty {

                    VStack {
                        Spacer()
                        Text("No providers connected")
                            .font(themeManager.currentTheme.bodyFont)
                            .foregroundColor(themeManager.currentTheme.textMutedColor)
                            .multilineTextAlignment(.center)
                            .padding(24)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                } else {

                    List {
                        ForEach(store.rows) { row in
                            ProviderLocationRowView(
                                row: row,
                                selected: row.id == store.selectedClientId,
                                onSelect: { store.select(row.id) }
                            )
                            .listRowBackground(themeManager.currentTheme.backgroundColor)
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                            // swipe alone never removes: the destructive action
                            // has to be tapped (allowsFullSwipe: false), the
                            // same rule the blocked-locations list uses
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    store.removeProvider(row)
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .background(themeManager.currentTheme.backgroundColor)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(themeManager.currentTheme.backgroundColor)
        .onAppear {
            if let device = deviceManager.device {
                store.setup(device)
            }
        }
        .onDisappear {
            store.reset()
        }
    }

    private var unavailableState: some View {
        VStack {
            Spacer()
            HStack(spacing: 8) {
                Circle()
                    .fill(themeManager.currentTheme.textMutedColor)
                    .frame(width: 8, height: 8)
                Text("Provider details are unavailable until connected")
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(themeManager.currentTheme.textMutedColor)
            }
            .padding(24)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/**
 * One provider: a fixed-size country-color dot column on the left (so the row
 * never shifts when the selection ring appears) and four stacked labels on the
 * right — the client id (tap to copy), the place, the coordinates, and how long
 * the provider has been connected.
 */
private struct ProviderLocationRowView: View {

    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var snackbarManager: UrSnackbarManager

    let row: ProviderLocationRow
    let selected: Bool
    let onSelect: () -> Void

    private static let rowPadding: CGFloat = 16

    var body: some View {
        HStack(alignment: .top, spacing: Self.rowPadding) {

            ProviderSelectableDot(color: providerDotColor(row), selected: selected)

            VStack(alignment: .leading, spacing: 2) {

                // the client id, tap to copy
                Text(row.id)
                    .font(.system(size: 11, weight: .medium).monospaced())
                    .foregroundColor(
                        selected
                            ? themeManager.currentTheme.textColor
                            : themeManager.currentTheme.textFaintColor
                    )
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        copyClientId()
                    }

                Text(providerPlaceLabel(row))
                    .font(themeManager.currentTheme.bodyFont)
                    .foregroundColor(themeManager.currentTheme.textColor)
                    .lineLimit(2)

                Text(providerCoordinatesLabel(row))
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(themeManager.currentTheme.textMutedColor)
                    .lineLimit(1)

                // the duration ticks locally against the absolute
                // connected-since stamp. The timeline is scoped to this label
                // so the per-second tick never reaches the globe above.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(providerConnectedDurationLabel(row, now: context.date))
                        .font(themeManager.currentTheme.secondaryBodyFont)
                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Self.rowPadding)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
        }
        .contextMenu {
            Button {
                copyClientId()
            } label: {
                Label("Copy client ID", systemImage: "doc.on.doc")
            }
        }
    }

    private func copyClientId() {
        #if os(iOS)
        UIPasteboard.general.string = row.id
        #elseif os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(row.id, forType: .string)
        #endif
        snackbarManager.showSnackbar(message: String(localized: "Client ID copied"))
    }
}

/**
 * The country-color dot in its fixed-size column. The selection ring is an
 * outline sitting `ringGap` outside the dot's edge and is drawn inside the same
 * box, so the column width never changes with the selection.
 */
private struct ProviderSelectableDot: View {

    let color: Color
    let selected: Bool

    // matches ProviderColorCircle, so a country reads the same size everywhere
    #if os(iOS)
    private static let diameter: CGFloat = 40
    #else
    private static let diameter: CGFloat = 30
    #endif
    private static let ringGap: CGFloat = 4
    private static let ringStroke: CGFloat = 1.5
    private static let box = diameter + (ringGap + ringStroke) * 2

    var body: some View {
        ZStack {
            Circle()
                .fill(color)
                .frame(width: Self.diameter, height: Self.diameter)
            if selected {
                Circle()
                    .stroke(color, lineWidth: Self.ringStroke)
                    .frame(
                        width: Self.diameter + 2 * Self.ringGap + Self.ringStroke,
                        height: Self.diameter + 2 * Self.ringGap + Self.ringStroke
                    )
            }
        }
        .frame(width: Self.box, height: Self.box)
    }
}

// MARK: - row labels
//
// Free functions rather than view helpers so the formatting is exercised
// directly by the unit tests.

/// "City, Region, Country", omitting whichever parts the server does not know.
func providerPlaceLabel(_ row: ProviderLocationRow) -> String {
    let parts = [row.city, row.region, row.country].filter { !$0.isEmpty }
    if !row.hasLocation || parts.isEmpty {
        return String(localized: "Location unknown")
    }
    return parts.joined(separator: ", ")
}

/// "37.7749, -122.4194", or an em dash when the provider has no coordinates.
func providerCoordinatesLabel(_ row: ProviderLocationRow) -> String {
    guard let lat = row.lat, let lon = row.lon else {
        return "—"
    }
    // no locale argument: a fixed decimal separator, as on android
    return String(format: "%.4f, %.4f", lat, lon)
}

/// How long the provider has been connected, as "3h 24m" / "24m" / "42s".
/// Empty when the SDK has no connected-since stamp (an older device peer).
func providerConnectedDurationLabel(_ row: ProviderLocationRow, now: Date) -> String {
    guard 0 < row.connectedSinceMillis else {
        return ""
    }
    let nowMillis = Int64(now.timeIntervalSince1970 * 1000)
    let elapsedSeconds = max(0, nowMillis - row.connectedSinceMillis) / 1000
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
