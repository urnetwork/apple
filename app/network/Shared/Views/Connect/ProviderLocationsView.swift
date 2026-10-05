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
 * The rows are in the SDK view controller's display order, west to east, so
 * scrolling the list and stepping the wheel walk the providers the same way.
 * (They were once sorted by connected duration, which put the rows in an order
 * the wheel did not follow.)
 *
 * There is deliberately no device-location sync here. Core Location has no
 * injection point an app can reach on a shipping device (see
 * PROVIDERLOCATIONS.md, "Apple"), so the Android toggle has no counterpart.
 *
 * The selected row offers "Stay on this exit" (see `stayOnExitState`), which
 * reconnects to that one provider by its client id.
 */
struct ProviderLocationsView: View {

    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var deviceManager: DeviceManager
    @EnvironmentObject var connectViewModel: ConnectViewModel
    @Environment(\.dismiss) private var dismiss

    @StateObject private var store = ProviderLocationsStore()
    @StateObject private var identityStore = PostQuantumIdentityStore()

    // providers with an identity-verified e2e session, keyed by the same
    // egress client id the rows carry — membership is the "end-to-end
    // encrypted" signal, and the value is the peer's identity identicon
    // rendered at badge size (see ProviderIdentityRow.identiconBadge)
    private var pqIdenticonByClientId: [String: IdenticonImage] {
        var byClientId: [String: IdenticonImage] = [:]
        for identity in identityStore.providerIdentities {
            if let badge = identity.identiconBadge {
                byClientId[identity.clientId] = badge
            }
        }
        return byClientId
    }

    // the client id of the current location when it is a client id location
    // (a stayed exit or a network peer)
    private var stayingClientId: String? {
        connectViewModel.selectedProvider?.connectLocationId?.clientId?.idStr
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {

                // the globe is fixed at the top and the list scrolls under it;
                // its height is set explicitly because two flexible siblings in
                // a VStack would otherwise negotiate the split between them
                ProviderGlobeView(
                    rows: store.rows,
                    selectedClientId: store.selectedClientId,
                    onSelect: { store.select($0) },
                    onStep: { store.step($0) }
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

                    // ScrollViewReader so the selection can be brought on
                    // screen: it moves without the list being touched — a wheel
                    // step on the globe, the default landing on the longest
                    // connected provider, a removal handing it to the nearest.
                    ScrollViewReader { proxy in
                        List {
                            ForEach(store.rows) { row in
                                ProviderLocationRowView(
                                    row: row,
                                    selected: row.id == store.selectedClientId,
                                    onSelect: { store.select(row.id) },
                                    pqIdenticon: pqIdenticonByClientId[row.id],
                                    stayState: stayOnExitState(
                                        row,
                                        selectedClientId: store.selectedClientId,
                                        stayingClientId: stayingClientId
                                    ),
                                    // the context menu offers it on any provider
                                    // the connection does not already stay on
                                    onStay: stayOnExitState(
                                        row,
                                        selectedClientId: row.id,
                                        stayingClientId: stayingClientId
                                    ) == .offer ? { stayOnExit(row) } : nil
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
                        .onChange(of: store.selectedClientId) { selected in
                            guard let selected else {
                                return
                            }
                            // scrollTo without an anchor moves the minimum
                            // needed, so a row already on screen stays put
                            withAnimation {
                                proxy.scrollTo(selected)
                            }
                        }
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(themeManager.currentTheme.backgroundColor)
        .onAppear {
            if let device = deviceManager.device {
                store.setup(device)
                identityStore.setup(device)
            }
        }
        .onDisappear {
            store.reset()
            identityStore.reset()
        }
    }

    /**
     * Stay on this exit: reconnect to the one provider, through the same
     * connect gate as a location pick, and return to the grid.
     */
    private func stayOnExit(_ row: ProviderLocationRow) {
        connectViewModel.connect(stayOnExitLocation(row))
        dismiss()
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
 * the provider has been connected — then the "Stay on this exit" action on the
 * selected row, or the line that says the connection already stays here.
 */
private struct ProviderLocationRowView: View {

    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var snackbarManager: UrSnackbarManager

    let row: ProviderLocationRow
    let selected: Bool
    let onSelect: () -> Void
    // the provider's post-quantum identity identicon at badge size, non-nil
    // only when the provider has an identity-verified end-to-end encrypted
    // session; rendered as a small badge to the right of the client id
    let pqIdenticon: IdenticonImage?
    let stayState: StayOnExitState
    // stays on this provider; nil when the connection already stays on it
    let onStay: (() -> Void)?

    private static let rowPadding: CGFloat = 16

    var body: some View {
        HStack(alignment: .top, spacing: Self.rowPadding) {

            ProviderSelectableDot(color: providerDotColor(row), selected: selected)

            VStack(alignment: .leading, spacing: 2) {

                // the client id, tap to copy, with the identity identicon as a
                // trailing badge when the session is verified end-to-end
                // encrypted. The badge is conditionally built — never
                // IdenticonView(image: nil, ...), which draws the placeholder
                // square — so absence is the "not e2e" state.
                HStack(alignment: .center, spacing: 6) {
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
                    if let pqIdenticon {
                        IdenticonView(
                            image: pqIdenticon,
                            size: PostQuantumIdentityStore.badgeIdenticonSize
                        )
                        .accessibilityLabel(String(localized: "Post Quantum Encryption"))
                    }
                }

                // the place, with the provider's address families as a small
                // tag: "both", "v4" or "v6", the same words as the histogram
                // rows in the connect drawer
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(providerPlaceLabel(row))
                        .font(themeManager.currentTheme.bodyFont)
                        .foregroundColor(themeManager.currentTheme.textColor)
                        .lineLimit(2)
                    ProviderIpFamilyTag(label: providerIpFamilyTagLabel(row))
                }

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

                switch stayState {
                case .offer:
                    Text("Keeps this provider's IP address until it goes offline.")
                        .font(themeManager.currentTheme.secondaryBodyFont)
                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                        .padding(.top, 4)
                    if let onStay {
                        // borderless, so only the button takes the tap and the
                        // row's own tap still selects
                        Button(action: onStay) {
                            Text("Stay on this exit")
                                .font(themeManager.currentTheme.secondaryBodyFont)
                        }
                        .buttonStyle(.borderless)
                    }
                case .staying:
                    Text("Staying on this exit. If it goes offline, choose another location.")
                        .font(themeManager.currentTheme.secondaryBodyFont)
                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                        .padding(.top, 4)
                case .none:
                    EmptyView()
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
            if let onStay {
                Button(action: onStay) {
                    Label("Stay on this exit", systemImage: "pin")
                }
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

/**
 * The provider's address families as a small capsule: the SDK's label
 * verbatim ("both", "v4", "v6"), monospaced like the client id.
 */
private struct ProviderIpFamilyTag: View {

    @EnvironmentObject var themeManager: ThemeManager

    let label: String

    var body: some View {
        Text(verbatim: label)
            .font(.system(size: 10, weight: .medium).monospaced())
            .foregroundColor(themeManager.currentTheme.textMutedColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(themeManager.currentTheme.borderBaseColor))
            .accessibilityLabel(providerIpFamilyAccessibilityLabel(label))
    }
}

// MARK: - row labels
//
// Free functions rather than view helpers so the formatting is exercised
// directly by the unit tests.

/// The address-family tag: the SDK's label when it has one, else "v4", which
/// is what a provider with no category carries.
func providerIpFamilyTagLabel(_ row: ProviderLocationRow) -> String {
    row.ipFamilyLabel.isEmpty ? SdkIpFamilyLabelV4 : row.ipFamilyLabel
}

/// The spoken form of the tag.
func providerIpFamilyAccessibilityLabel(_ label: String) -> String {
    switch label {
    case SdkIpFamilyLabelBoth:
        return String(localized: "IPv4 and IPv6")
    case SdkIpFamilyLabelV6:
        return String(localized: "IPv6")
    default:
        return String(localized: "IPv4")
    }
}

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

// MARK: - stay on this exit
//
// "Stay on this exit" reconnects to one provider of the current connection, by
// its client id, so new connections keep that provider's IP address. The SDK
// dials a client id location directly (connect's fixed destination: nothing is
// discovered and nothing replaces it), and the location is not marked as a
// network peer, so the provider keeps carrying the traffic as the public exit
// it already is. The rows are the user's own current exits, so this pins one
// of them; it is not a way to browse or pick from all providers.

/// What a provider row shows for "Stay on this exit".
enum StayOnExitState: Equatable {
    case none
    /// the selected row offers the action
    case offer
    /// the connection already stays on this provider
    case staying
}

/// The selected row offers to stay on its provider; the provider the connection
/// already stays on says so instead, selected or not. `stayingClientId` is the
/// client id of the current location when it is a client id location (a stayed
/// exit or a network peer).
func stayOnExitState(
    _ row: ProviderLocationRow,
    selectedClientId: String?,
    stayingClientId: String?
) -> StayOnExitState {
    let clientId = row.id
    if clientId.isEmpty {
        return .none
    }
    if let stayingClientId, clientId.caseInsensitiveCompare(stayingClientId) == .orderedSame {
        return .staying
    }
    if let selectedClientId, clientId.caseInsensitiveCompare(selectedClientId) == .orderedSame {
        return .offer
    }
    return .none
}

/// "018f…5c6d": the first and last four characters of a client id, the form the
/// Android connect drawer shows a client id location in. A short id is returned
/// as it is.
func shortClientId(_ clientId: String) -> String {
    let id = clientId.trimmingCharacters(in: .whitespaces)
    if id.count <= 12 {
        return id
    }
    return "\(id.prefix(4))…\(id.suffix(4))"
}

/// "018f…5c6d · Berlin, Germany": the short client id, which is what makes the
/// location one provider, then the city (or the region) and the country. The
/// id comes first so a narrow drawer trims the place rather than the id. Just
/// the short id when the server does not know where the provider is.
func stayOnExitName(_ row: ProviderLocationRow) -> String {
    let shortId = shortClientId(row.id)
    guard row.hasLocation else {
        return shortId
    }
    let place = [row.city.isEmpty ? row.region : row.city, row.country]
        .filter { !$0.isEmpty }
        .joined(separator: ", ")
    return place.isEmpty ? shortId : "\(shortId) · \(place)"
}

/// The location "Stay on this exit" connects to: the provider alone, by its
/// client id, as a public exit rather than one of the user's own network peers
/// (which would egress under the network provide mode).
func stayOnExitLocation(_ row: ProviderLocationRow) -> SdkConnectLocation {
    let location = SdkConnectLocation()
    let locationId = SdkConnectLocationId()
    locationId.clientId = row.clientId
    location.connectLocationId = locationId
    location.name = stayOnExitName(row)
    location.city = row.city
    location.region = row.region
    location.country = row.country
    location.countryCode = row.countryCode
    location.networkPeer = false
    return location
}
