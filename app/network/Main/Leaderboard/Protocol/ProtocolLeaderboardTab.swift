//
//  ProtocolLeaderboardTab.swift
//  URnetwork
//
//  The Protocol tab of the leaderboard (apple/LEADERTOP.md, owner decision
//  2026-10-29): whether a network would make the SN25 validator's Top 200 if
//  it claimed now. At compact width the status banner, the own-status card
//  and the explainer lead the ranked list; in a regular-width window they
//  show in the second pane (ProtocolSidePane) and the list takes the first.
//  Rows and pages come from ProtocolTopStore; nothing here ranks or pages.
//

import SwiftUI
import URnetworkSdk

struct ProtocolLeaderboardTab: View {

    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var deviceManager: DeviceManager
    @Environment(\.presentationActive) private var presentationActive

    @ObservedObject var store: ProtocolTopStore
    /// holds the shared "Show my network name" switch
    @ObservedObject var pointsStore: PointsLeaderboardStore

    /// bumped by the leaderboard's tab picker on every tap, selected tab
    /// included: the list scrolls back to its top
    var scrollResetToken: Int = 0
    /// the banner, card and explainer lead the list; in a regular-width
    /// window they show in the other pane
    var showsStatus: Bool = true
    /// a regular-width pane: the claimed UID and the trend get columns
    var isWide: Bool = false
    /// Claim on Earnings: Account › Earnings at its Top 200 tile
    let claimOnEarnings: () -> Void

    // the position indicator: which rows are on screen (the lowest is where
    // the thumb sits, their count its length), the list and viewport heights
    // that decide whether it shows, and the rank held while the thumb is
    // dragged and until its seek lands
    @State private var visibleRows = PointsVisibleRows()
    @State private var firstVisiblePosition: Int = 0
    @State private var visibleCount: Int = 0
    @State private var contentHeight: CGFloat = 0
    @State private var indicatorRank: Int64? = nil
    // the caller's row and the status column on screen: the You pill shows
    // while neither is
    @State private var ownRowVisible = false
    @State private var statusVisible = false
    @State private var detailRow: SnTopRowInfo? = nil

    private var indicatorPosition: Int64 {
        if let indicatorRank {
            return indicatorRank
        }
        return Int64(max(1, firstVisiblePosition))
    }

    var body: some View {
        let state = store.state

        ScrollViewReader { proxy in
            GeometryReader { viewport in
                let indicatorShown = state.listContent == .list && PointsLeaderboardIndicator.isShown(
                    total: Int64(state.trackTotal),
                    firstLoadedPosition: 1,
                    contentHeight: contentHeight,
                    viewportHeight: viewport.size.height
                )

                ScrollView {
                    LazyVStack(spacing: 0) {
                        VStack(spacing: 0) {
                            if showsStatus {
                                ProtocolStatusColumn(
                                    store: store,
                                    pointsStore: pointsStore,
                                    claimOnEarnings: claimOnEarnings
                                )
                                .padding(.horizontal)
                                .padding(.top)
                                .padding(.bottom, 16)
                            } else {
                                Spacer().frame(height: 8)
                            }
                        }
                        .id(LeaderboardListAnchor.top)
                        .onAppear {
                            statusVisible = true
                        }
                        .onDisappear {
                            statusVisible = false
                        }

                        listBody(state)
                    }
                    .background(
                        // the list's full height against the viewport's decides
                        // whether the indicator shows; written only on change
                        GeometryReader { content in
                            Color.clear
                                .onAppear {
                                    contentChanged(height: content.size.height)
                                }
                                .onChange(of: content.size.height) { height in
                                    contentChanged(height: height)
                                }
                        }
                    )
                    // room for the thumb beside the scores
                    .padding(.trailing, indicatorShown ? PointsLeaderboardIndicator.thumbWidth : 0)
                }
                // the built-in bar spans the loaded rows; ours spans the board
                .scrollIndicators(indicatorShown ? .hidden : .automatic)
                .overlay(alignment: .trailing) {
                    if indicatorShown {
                        PointsPositionIndicator(
                            total: Int64(state.trackTotal),
                            windowCount: Int64(max(1, visibleCount)),
                            position: indicatorPosition,
                            isSeeking: state.seekTarget != nil,
                            label: { rank in
                                let total = Int64(max(state.snapshot?.totalRanked ?? 0, state.trackTotal))
                                return SdkPointsLeaderboardScrollLabel(rank, total).map(PointsLeaderboardScrollLabel.init)
                            },
                            onDrag: { rank in
                                indicatorRank = rank
                            },
                            onSeek: { rank in
                                indicatorRank = rank
                                store.seek(to: Int(rank))
                            }
                        )
                    }
                }
                .overlay(alignment: .bottom) {
                    youPill(state)
                }
                .onChange(of: scrollResetToken) { _ in
                    indicatorRank = nil
                    store.tabTapped()
                }
                .onChange(of: store.state.scrollRequest) { request in
                    scroll(request, proxy: proxy)
                }
                .onChange(of: store.state.pageFailed) { failed in
                    if failed {
                        // a failed seek: the thumb follows the list again
                        indicatorRank = nil
                    }
                }
            }
        }
        #if os(iOS)
        .refreshable {
            await store.refreshAndWait()
        }
        #elseif os(macOS)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button(action: {
                    store.refresh()
                }) {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(store.state.listLoading)
            }
        }
        #endif
        .onReceive(deviceManager.$device) { device in
            store.setClient(SnTopSdk.client(deviceManager.api), session: device)
            pointsStore.deviceChanged(device: device, api: deviceManager.api)
        }
        .onReceive(deviceManager.$parsedJwt) { jwt in
            store.setSignedIn(jwt != nil)
        }
        .onAppear {
            pointsStore.open(.protocolCard, device: deviceManager.device, api: deviceManager.api)
            store.setPresentationActive(presentationActive)
            store.setOnScreen(true)
        }
        .onChange(of: presentationActive) { active in
            store.setPresentationActive(active)
        }
        .onDisappear {
            store.setOnScreen(false)
            pointsStore.close(.protocolCard)
        }
        .sheetOffTheFold(item: $detailRow) { row in
            ProtocolClaimedDetailSheet(row: row, dismiss: { detailRow = nil })
                .environmentObject(themeManager)
                #if os(iOS)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                #elseif os(macOS)
                .frame(minWidth: 420, minHeight: 520)
                #endif
        }
    }

    @ViewBuilder
    private func listBody(_ state: ProtocolTopState) -> some View {
        switch state.listContent {
        case .loading:
            ProtocolRowPlaceholders()
        case .failed:
            SectionLoadFailedView(retry: {
                store.retryList()
            })
            .padding()
        case .empty:
            Text(verbatim: ProtocolText.empty)
                .font(themeManager.currentTheme.bodyFont)
                .foregroundStyle(themeManager.currentTheme.textMutedColor)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding()
        case .list:
            if state.refreshFailed {
                refreshFailedNotice
            }
            ForEach(Array(state.rows.enumerated()), id: \.element.id) { index, row in
                VStack(spacing: 0) {
                    Divider()
                    ProtocolRowView(
                        row: row,
                        isWide: isWide,
                        open: row.claimed ? { detailRow = row } : nil
                    )
                    if ProtocolLine.follows(row.position) {
                        ProtocolLineDivider(cutoff: state.snapshot?.projectedCutoff ?? 0)
                    }
                }
                .onAppear {
                    rowAppeared(row, index: index)
                }
                .onDisappear {
                    rowDisappeared(row)
                }
            }
            footer(state)
        }
    }

    /// A refresh failed: the rows stay, with this notice.
    private var refreshFailedNotice: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(themeManager.currentTheme.textMutedColor)
                .accessibilityHidden(true)
            Text("Couldn't refresh. Showing the last list.")
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundStyle(themeManager.currentTheme.textColor)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Retry") {
                store.refresh()
            }
            .buttonStyle(.plain)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(themeManager.currentTheme.accentColor)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func footer(_ state: ProtocolTopState) -> some View {
        VStack(spacing: 8) {
            if state.pageLoading {
                ProgressView()
            } else if state.pageFailed {
                SectionLoadFailedView(retry: {
                    store.retryList()
                })
            } else {
                Spacer().frame(height: 8)
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
        // room for the You pill over the last rows
        .padding(.bottom, 56)
    }

    /// The caller's standing, pinned to the bottom while neither its row nor
    /// the card is on screen; a tap scrolls to its row, or to the card when
    /// it ranks below the list.
    @ViewBuilder
    private func youPill(_ state: ProtocolTopState) -> some View {
        if state.listContent == .list,
           let own = state.ownRow,
           !ownRowVisible,
           (showsStatus ? !statusVisible : own.position <= ProtocolTopState.maxPosition) {
            let listed = own.position <= ProtocolTopState.maxPosition
            ProtocolYouPill(
                row: own,
                pointsUp: listed ? own.position < max(1, firstVisiblePosition) : true,
                action: {
                    if listed {
                        store.seek(to: own.position)
                    } else {
                        store.tabTapped()
                    }
                }
            )
            .padding(.horizontal)
            .padding(.bottom, 12)
        }
    }

    private func rowAppeared(_ row: SnTopRowInfo, index: Int) {
        visibleRows.insert(Int64(row.position))
        updateVisibleRows()
        if row.isMe {
            ownRowVisible = true
        }
        let state = store.state
        if PointsLeaderboardPaging.shouldLoadMore(
            lastVisibleRowIndex: index,
            rowCount: state.rows.count,
            isLoading: state.pageLoading || state.listLoading,
            isEndReached: !state.hasMore,
            hasError: state.pageFailed
        ) {
            store.loadMore()
        }
    }

    private func rowDisappeared(_ row: SnTopRowInfo) {
        visibleRows.remove(Int64(row.position))
        updateVisibleRows()
        if row.isMe {
            ownRowVisible = false
        }
    }

    private func updateVisibleRows() {
        let first = Int(visibleRows.first)
        if first != firstVisiblePosition {
            firstVisiblePosition = first
        }
        let count = visibleRows.count
        if count != visibleCount {
            visibleCount = count
        }
    }

    private func contentChanged(height: CGFloat) {
        if height != contentHeight {
            contentHeight = height
        }
    }

    /// The store asked for a scroll: the tab reset, or a seek that landed.
    private func scroll(_ request: ProtocolScrollRequest?, proxy: ScrollViewProxy) {
        guard let request else {
            return
        }
        indicatorRank = nil
        switch request.target {
        case .top:
            withAnimation {
                proxy.scrollTo(LeaderboardListAnchor.top, anchor: .top)
            }
        case .position(let position):
            // after the rows the seek loaded are laid out
            DispatchQueue.main.async {
                proxy.scrollTo(position, anchor: .top)
            }
        }
    }
}

/// One ranked network: the position, the tag and name (Anonymous, or the
/// fleets' UIDs for an anonymous claimed network), the projected score with
/// its trend, the claimed UID, and the label chip on the caller's own row
/// only. Rows above the 200 line are tinted; rows the validator cannot
/// measure are dimmed. A claimed row opens its detail sheet.
struct ProtocolRowView: View {

    @EnvironmentObject var themeManager: ThemeManager

    let row: SnTopRowInfo
    var isWide: Bool = false
    /// opens the claimed detail sheet; nil for an unclaimed row
    var open: (() -> Void)? = nil

    /// every row the same height, so a placeholder stands in exactly
    static let minHeight: CGFloat = 56

    var body: some View {
        let label = ProtocolRowAccessibility.label(row)
        if let open {
            Button(action: open) {
                content
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: label))
        } else {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: label))
        }
    }

    private var name: ProtocolName {
        ProtocolName.of(row)
    }

    private var nameColor: Color {
        if row.isMe {
            return .urGreen
        }
        if name.isAnonymous {
            return themeManager.currentTheme.textMutedColor
        }
        return themeManager.currentTheme.textColor
    }

    private var background: Color {
        if row.isMe {
            return Color.urGreen.opacity(0.08)
        }
        if ProtocolLine.isAbove(row.position) {
            return themeManager.currentTheme.accentColor.opacity(0.12)
        }
        return .clear
    }

    private var content: some View {
        HStack(spacing: 8) {
            Text(verbatim: ProtocolFormat.count(row.position))
                .font(themeManager.currentTheme.bodyFont)
                .fontWeight(row.isMe ? .heavy : .regular)
                .foregroundStyle(row.isMe ? Color.urGreen : themeManager.currentTheme.textMutedColor)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: isWide ? 56 : 40, alignment: .leading)

            // the name on the first line and the emoji tag below it, as the
            // points rows stack them
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: name.text)
                    .font(themeManager.currentTheme.bodyFont)
                    .fontWeight(row.isMe ? .heavy : .regular)
                    .foregroundStyle(nameColor)
                    .lineLimit(1)
                if !row.tag.isEmpty {
                    Text(verbatim: row.tag)
                        .font(themeManager.currentTheme.bodyFont)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !row.measurable {
                Image(systemName: "eye.slash")
                    .font(.system(size: 12))
                    .foregroundStyle(themeManager.currentTheme.textMutedColor)
                    .accessibilityHidden(true)
            }

            if row.isMe, let label = row.label {
                ProtocolLabelChip(label: label, compact: true)
            }

            if isWide {
                // the claimed column
                Group {
                    if let fleet = row.fleets.first {
                        ProtocolUidBadge(uid: fleet.uid)
                    } else {
                        Color.clear.frame(height: 1)
                    }
                }
                .frame(width: 96, alignment: .leading)

                ProtocolTrendGlyph(trend: row.trend, showsCount: true)
                    .frame(width: 56, alignment: .trailing)
            } else if let fleet = row.fleets.first {
                ProtocolUidBadge(uid: fleet.uid)
            }

            HStack(spacing: 3) {
                Text(verbatim: ProtocolFormat.score(row.projectedScore))
                    .font(themeManager.currentTheme.bodyFont)
                    .fontWeight(row.isMe ? .heavy : .regular)
                    .foregroundStyle(row.isMe ? Color.urGreen : themeManager.currentTheme.textColor)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if !isWide {
                    ProtocolTrendGlyph(trend: row.trend, showsCount: false)
                }
            }
            .frame(width: isWide ? 72 : 76, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(minHeight: Self.minHeight)
        .background(background)
        .opacity(row.measurable ? 1 : 0.55)
    }
}

/// Rows the size of the real ones while the first page loads.
struct ProtocolRowPlaceholders: View {

    var count: Int = 8

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { index in
                VStack(spacing: 0) {
                    Divider()
                    HStack(spacing: 8) {
                        Skeleton(width: 28, height: 12)
                            .frame(width: 40, alignment: .leading)
                        Skeleton(width: CGFloat(110 + (index % 3) * 24), height: 14)
                        Spacer(minLength: 0)
                        Skeleton(width: 44, height: 14)
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: ProtocolRowView.minHeight)
                }
            }
        }
        .skeletonGroup("Loading...")
    }
}

/// The divider between positions 200 and 201: "Top 200 line · score 41.2".
struct ProtocolLineDivider: View {

    @EnvironmentObject var themeManager: ThemeManager

    let cutoff: Double

    var body: some View {
        HStack(spacing: 8) {
            ProtocolDashedRule()
                .stroke(Color.urLightBlue, style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
                .frame(height: 2)
            Text(verbatim: ProtocolText.line(cutoff: cutoff))
                .font(themeManager.currentTheme.secondaryBodyFont.weight(.bold))
                .foregroundStyle(Color.urLightBlue)
                .lineLimit(1)
                .fixedSize()
            ProtocolDashedRule()
                .stroke(Color.urLightBlue, style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
                .frame(width: 12, height: 2)
        }
        .padding(.horizontal, 16)
        .frame(height: 36)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: ProtocolText.lineAccessibility(cutoff: cutoff)))
    }
}

/// A horizontal line through the middle of its frame, to stroke dashed.
struct ProtocolDashedRule: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

/// A recommendation label as a chip; it reads as text.
struct ProtocolLabelChip: View {

    @EnvironmentObject var themeManager: ThemeManager

    let label: SnTopLabel
    /// the smaller chip of a row
    var compact: Bool = false

    private var foreground: Color {
        switch label {
        case .likely:
            return .urGreen
        case .borderline:
            return .urAmber
        case .estimate:
            return themeManager.currentTheme.textColor.opacity(0.85)
        case .unlikely, .notMeasurable:
            return themeManager.currentTheme.textMutedColor
        }
    }

    private var fill: Color {
        switch label {
        case .likely:
            return Color.urGreen.opacity(0.12)
        case .borderline:
            return Color.urAmber.opacity(0.12)
        case .estimate, .unlikely, .notMeasurable:
            return .clear
        }
    }

    private var stroke: Color {
        switch label {
        case .likely:
            return Color.urGreen.opacity(0.45)
        case .borderline:
            return Color.urAmber.opacity(0.45)
        case .estimate:
            return themeManager.currentTheme.textMutedColor.opacity(0.7)
        case .unlikely, .notMeasurable:
            return themeManager.currentTheme.borderEmphasisColor
        }
    }

    var body: some View {
        Text(verbatim: ProtocolText.label(label))
            .font(compact
                ? themeManager.currentTheme.secondaryBodyFont
                : themeManager.currentTheme.secondaryBodyFont.weight(.semibold))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .padding(.horizontal, compact ? 7 : 9)
            .padding(.vertical, compact ? 2 : 3)
            .background(Capsule().fill(fill))
            .overlay(Capsule().stroke(stroke, lineWidth: 1))
            .fixedSize()
    }
}

/// A claimed network's UID: "UID 81".
struct ProtocolUidBadge: View {

    @EnvironmentObject var themeManager: ThemeManager

    let uid: Int64

    var body: some View {
        Text(verbatim: ProtocolText.uid(uid))
            .font(themeManager.currentTheme.secondaryBodyFont.weight(.semibold))
            .foregroundStyle(Color.urLightBlue)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(themeManager.currentTheme.accentColor.opacity(0.35))
            )
            .fixedSize()
    }
}

/// Positions moved since the last tempo: an arrow, up in blue and down in
/// amber, with the count in a column of its own.
struct ProtocolTrendGlyph: View {

    @EnvironmentObject var themeManager: ThemeManager

    let trend: Int
    var showsCount: Bool = false

    var body: some View {
        if trend == 0 {
            if showsCount {
                Text(verbatim: "–")
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundStyle(themeManager.currentTheme.textFaintColor)
                    .accessibilityHidden(true)
            }
        } else {
            HStack(spacing: 2) {
                Image(systemName: trend > 0 ? "arrow.up" : "arrow.down")
                    .font(.system(size: showsCount ? 11 : 10, weight: .bold))
                if showsCount {
                    Text(verbatim: ProtocolFormat.count(abs(trend)))
                        .font(themeManager.currentTheme.secondaryBodyFont)
                        .monospacedDigit()
                }
            }
            .foregroundStyle(trend > 0 ? Color.urLightBlue : Color.urAmber)
            .accessibilityHidden(true)
        }
    }
}

/// The caller's standing pinned over the list: You, the rank and the margin.
struct ProtocolYouPill: View {

    @EnvironmentObject var themeManager: ThemeManager

    let row: SnTopRowInfo
    /// the row is above what is on screen
    let pointsUp: Bool
    let action: () -> Void

    var body: some View {
        let rank = ProtocolFormat.rank(row.position)
        let margin = ProtocolText.margin(row.margin)
        Button(action: action) {
            HStack(spacing: 10) {
                Text(verbatim: ProtocolText.you)
                    .font(themeManager.currentTheme.secondaryBodyFont.weight(.bold))
                    .foregroundStyle(Color.urGreen)
                Text(verbatim: rank)
                    .font(themeManager.currentTheme.bodyFont.weight(.bold))
                    .foregroundStyle(themeManager.currentTheme.textColor)
                    .monospacedDigit()
                Text(verbatim: margin)
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundStyle(themeManager.currentTheme.textColor.opacity(0.85))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: pointsUp ? "arrow.up" : "arrow.down")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.urGreen)
            }
            .padding(.horizontal, 14)
            .frame(height: 48)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(themeManager.currentTheme.tintedBackgroundBase)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.urGreen.opacity(0.45), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: [ProtocolText.you, rank, margin].joined(separator: ", ")))
        .accessibilityIdentifier("leaderboard.protocol.you")
    }
}

/// The banner, the own-status card and the explainer beside the ranked list
/// in a regular-width window.
struct ProtocolSidePane: View {

    @ObservedObject var store: ProtocolTopStore
    @ObservedObject var pointsStore: PointsLeaderboardStore
    let claimOnEarnings: () -> Void

    var body: some View {
        ScrollView {
            ProtocolStatusColumn(
                store: store,
                pointsStore: pointsStore,
                claimOnEarnings: claimOnEarnings
            )
            .padding()
            .frame(maxWidth: TabletLayout.contentWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}
