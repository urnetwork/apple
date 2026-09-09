//
//  PointsLeaderboardTab.swift
//  URnetwork
//

import SwiftUI
import URnetworkSdk

/**
 * The Points tab of the leaderboard (android/POINTSLEADERBOARD.md): the
 * network's own stats and ranks, the opt-in switch and the emoji tag editor
 * in a header card, sort chips, and the infinitely scrolling ranked list.
 * Rows, ranks and pages all come from the sdk view controller through the
 * store; nothing here sorts, ranks or pages.
 */
struct PointsLeaderboardTab: View {
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var deviceManager: DeviceManager

    @ObservedObject var store: PointsLeaderboardStore

    /// bumped by the leaderboard's tab picker on every tap, selected tab
    /// included: the list scrolls back to its top
    var scrollResetToken: Int = 0

    @State private var showEmojiSheet: Bool = false
    @State private var emojiSaveError: String? = nil

    // the position indicator: which loaded rows are on screen (their lowest
    // rank is where the thumb sits), the list and viewport heights that decide
    // whether it shows at all, and the rank held while the thumb is dragged
    // and until the seek it released lands
    @State private var visibleRows = PointsVisibleRows()
    @State private var firstVisiblePosition: Int64 = 0
    @State private var contentHeight: CGFloat = 0
    @State private var indicatorRank: Int64? = nil
    /// scroll to the window's first row once the seeked page lands
    @State private var scrollToFirstRowOnLand: Bool = false
    /// the row that was first before a backward page; it is scrolled back
    /// under the finger once the page is prepended
    @State private var backwardAnchor: Int64? = nil

    private var ownNetworkId: String? {
        if let id = store.me?.row?.networkId, !id.isEmpty {
            return id
        }
        return deviceManager.parsedJwt?.networkId?.idStr
    }

    /// The own-stats card always shows the caller's own name: the me row's, or
    /// the jwt's until me lands. The list row is what everyone else sees.
    private var ownName: String {
        if let name = store.me?.row?.displayName, !name.isEmpty {
            return name
        }
        return deviceManager.parsedJwt?.networkName ?? ""
    }

    /// the rank the thumb shows: the drag's while it is held, else the first
    /// visible row's, else the window's first row (the header is on screen)
    private var indicatorPosition: Int64 {
        if let indicatorRank {
            return indicatorRank
        }
        if firstVisiblePosition > 0 {
            return firstVisiblePosition
        }
        return store.firstLoadedPosition
    }

    var body: some View {
        ScrollViewReader { proxy in
            GeometryReader { viewport in
                let indicatorShown = PointsLeaderboardIndicator.isShown(
                    total: store.totalRanked,
                    firstLoadedPosition: store.firstLoadedPosition,
                    contentHeight: contentHeight,
                    viewportHeight: viewport.size.height
                )

                ScrollView {
                    LazyVStack(spacing: 0) {
                        PointsHeader(
                            store: store,
                            ownName: ownName,
                            onEditEmoji: {
                                emojiSaveError = nil
                                showEmojiSheet = true
                            }
                        )
                        .id(LeaderboardListAnchor.top)

                        PointsSortChips(
                            sort: store.sort,
                            setSort: { store.selectSort($0) }
                        )

                        ForEach(Array(store.rows.enumerated()), id: \.element.id) { index, row in
                            VStack(spacing: 0) {
                                Divider()
                                PointsRow(
                                    row: row,
                                    sort: store.sort,
                                    isNetworkRow: ownNetworkId != nil && ownNetworkId == row.networkId
                                )
                            }
                            .onAppear {
                                rowAppeared(row, index: index)
                            }
                            .onDisappear {
                                rowDisappeared(row)
                            }
                        }

                        PointsFooter(
                            rowCount: store.rows.count,
                            isLoading: store.isLoading,
                            hasLoaded: store.hasLoaded,
                            errorMessage: store.errorMessage,
                            retry: { store.retry() }
                        )
                    }
                    .background(
                        // the list's full height, against the viewport's, decides whether
                        // the indicator shows; written only when it changes
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
                    // room for the thumb beside the values column
                    .padding(.trailing, indicatorShown ? PointsLeaderboardIndicator.thumbWidth : 0)
                }
                // the built-in bar spans only the loaded rows; ours spans the population
                .scrollIndicators(indicatorShown ? .hidden : .automatic)
                .overlay(alignment: .trailing) {
                    if indicatorShown {
                        PointsPositionIndicator(
                            total: store.totalRanked,
                            windowCount: max(0, store.lastLoadedPosition - store.firstLoadedPosition + 1),
                            position: indicatorPosition,
                            isSeeking: indicatorRank != nil && scrollToFirstRowOnLand,
                            label: { rank in store.scrollLabel(rank: rank) },
                            onDrag: { rank in
                                indicatorRank = rank
                            },
                            onSeek: { rank in
                                seek(to: rank)
                            }
                        )
                    }
                }
                .onChange(of: scrollResetToken) { _ in
                    resetToTop(proxy)
                }
                .onChange(of: store.rows) { rows in
                    rowsChanged(rows, proxy: proxy)
                }
                .onChange(of: store.errorMessage) { error in
                    if !error.isEmpty {
                        // a failed seek or backward page: the thumb goes back
                        // to following the list, nothing waits for a landing
                        indicatorRank = nil
                        scrollToFirstRowOnLand = false
                        backwardAnchor = nil
                    }
                }
            }
        }
        #if os(iOS)
        .refreshable {
            await refresh()
        }
        #elseif os(macOS)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button(action: {
                    store.refresh()
                }) {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(store.isLoading)
            }
        }
        #endif
        .onAppear {
            store.attach(device: deviceManager.device, api: deviceManager.api)
        }
        .onReceive(deviceManager.$device) { device in
            store.attach(device: device, api: deviceManager.api)
        }
        .onDisappear {
            store.detach()
        }
        .sheet(isPresented: $showEmojiSheet) {
            EmojiTagSheet(
                currentTag: store.emojiTag,
                isSaving: store.isSavingEmojiTag,
                saveError: emojiSaveError,
                onSave: { tag in
                    emojiSaveError = nil
                    store.saveEmojiTag(tag) { error in
                        if let error {
                            emojiSaveError = error
                        } else {
                            showEmojiSheet = false
                        }
                    }
                },
                onClear: {
                    emojiSaveError = nil
                    store.saveEmojiTag("") { error in
                        if let error {
                            emojiSaveError = error
                        } else {
                            showEmojiSheet = false
                        }
                    }
                },
                onDismiss: {
                    emojiSaveError = nil
                    showEmojiSheet = false
                }
            )
            .environmentObject(themeManager)
            #if os(iOS)
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            #endif
        }
        .alert(
            store.actionError ?? "",
            isPresented: Binding(
                get: { store.actionError != nil },
                set: { presented in
                    if !presented {
                        store.actionError = nil
                    }
                }
            )
        ) {
            Button(action: {
                store.actionError = nil
            }) {
                Text("Close")
            }
        }
    }

    /// pull to refresh: ask the controller for a fresh first page and hold the
    /// indicator until it lands (or a short cap, so it never spins forever)
    private func refresh() async {
        store.refresh()
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if !store.isLoading {
                return
            }
        }
    }

    /**
     * A row scrolled in: it joins the visible set (the thumb follows the lowest
     * rank on screen; the state is written only when that rank changes, never
     * per frame), the next page is asked for near the window's end, and the
     * page before the window when its first row shows with ranks above it.
     */
    private func rowAppeared(_ row: PointsLeaderboardRowItem, index: Int) {
        visibleRows.insert(row.position)
        updateFirstVisiblePosition()

        if PointsLeaderboardPaging.shouldLoadMore(
            lastVisibleRowIndex: index,
            rowCount: store.rows.count,
            isLoading: store.isLoading,
            isEndReached: store.isEndReached,
            hasError: !store.errorMessage.isEmpty
        ) {
            store.loadMore()
        }
        if backwardAnchor == nil && PointsLeaderboardPaging.shouldLoadBefore(
            rowPosition: row.position,
            firstLoadedPosition: store.firstLoadedPosition,
            hasMoreBefore: store.hasMoreBefore,
            isLoading: store.isLoading,
            hasError: !store.errorMessage.isEmpty
        ) {
            backwardAnchor = row.position
            store.loadMoreBefore()
        }
    }

    private func rowDisappeared(_ row: PointsLeaderboardRowItem) {
        visibleRows.remove(row.position)
        updateFirstVisiblePosition()
    }

    private func contentChanged(height: CGFloat) {
        if height != contentHeight {
            contentHeight = height
        }
    }

    private func updateFirstVisiblePosition() {
        let first = visibleRows.first
        if first != firstVisiblePosition {
            firstVisiblePosition = first
        }
    }

    /// The thumb was released on `rank`: the controller lands the page holding
    /// it and the list then scrolls to the top of that window.
    private func seek(to rank: Int64) {
        indicatorRank = rank
        scrollToFirstRowOnLand = true
        backwardAnchor = nil
        store.seekToRank(rank)
    }

    /**
     * The tab was tapped: scroll to the top of the list, and when the window
     * no longer starts at rank 1 have the controller reload from the top so
     * the top of the screen is rank 1 again.
     */
    private func resetToTop(_ proxy: ScrollViewProxy) {
        indicatorRank = nil
        scrollToFirstRowOnLand = false
        backwardAnchor = nil
        withAnimation {
            proxy.scrollTo(LeaderboardListAnchor.top, anchor: .top)
        }
        if PointsLeaderboardTabReset.reloadsFromTop(
            firstLoadedPosition: store.firstLoadedPosition,
            rowCount: store.rows.count
        ) {
            store.reloadFromTop()
        }
    }

    /**
     * The window changed. After a seek the new page's first row goes to the
     * top of the screen (the controller clears the rows first; that empty
     * change is skipped). After a backward page the row that was first is
     * scrolled back to where it was, so the prepended rows do not shove the
     * list under the finger.
     */
    private func rowsChanged(_ rows: [PointsLeaderboardRowItem], proxy: ScrollViewProxy) {
        guard let first = rows.first else {
            return
        }
        if scrollToFirstRowOnLand {
            scrollToFirstRowOnLand = false
            indicatorRank = nil
            proxy.scrollTo(first.id, anchor: .top)
            return
        }
        if let anchor = backwardAnchor {
            if first.position < anchor {
                proxy.scrollTo(PointsLeaderboardRowItem.scrollId(position: anchor, networkId: ""), anchor: .top)
            }
            backwardAnchor = nil
        }
    }
}

/// The ranks of the rows currently on screen, as `onAppear`/`onDisappear` report them.
private final class PointsVisibleRows {
    private var positions: Set<Int64> = []

    /// the lowest visible rank, 0 when no row is on screen
    var first: Int64 {
        positions.min() ?? 0
    }

    func insert(_ position: Int64) {
        positions.insert(position)
    }

    func remove(_ position: Int64) {
        positions.remove(position)
    }
}

/**
 * The draggable position indicator (mmm/DESIGNSTYLE.md): a faint track down
 * the trailing edge standing for ranks 1 to N, an accent thumb at the rank on
 * screen whose length is the loaded window over N, and, only while the thumb
 * is held, a label beside it with the rank and tier under it from the sdk's
 * helper. Dragging moves only the thumb; releasing seeks the controller.
 * The thumb is an adjustable accessibility element stepping one percent of
 * the population at a time.
 */
private struct PointsPositionIndicator: View {
    @EnvironmentObject var themeManager: ThemeManager

    let total: Int64
    let windowCount: Int64
    let position: Int64
    /// the thumb was released and its page has not landed yet
    let isSeeking: Bool
    let label: (Int64) -> PointsLeaderboardScrollLabel?
    let onDrag: (Int64) -> Void
    let onSeek: (Int64) -> Void

    @State private var isDragging: Bool = false
    @State private var dragStartOffset: CGFloat? = nil
    @State private var labelShown: Bool = false
    @State private var labelFade: Task<Void, Never>? = nil

    private let trackInset: CGFloat = 8
    private let barWidth: CGFloat = 6
    private let labelHeight: CGFloat = 44

    var body: some View {
        GeometryReader { geo in
            let trackLength = max(0, geo.size.height - 2 * trackInset)
            let thumbLength = PointsLeaderboardIndicator.thumbLength(
                windowCount: windowCount,
                total: total,
                trackLength: trackLength
            )
            let offset = PointsLeaderboardIndicator.thumbOffset(
                rank: position,
                total: total,
                trackLength: trackLength,
                thumbLength: thumbLength
            )

            ZStack(alignment: .topTrailing) {
                // the track: the whole population
                RoundedRectangle(cornerRadius: barWidth / 2)
                    .fill(themeManager.currentTheme.borderBaseColor)
                    .frame(width: barWidth, height: trackLength)
                    .padding(.trailing, (PointsLeaderboardIndicator.thumbWidth - barWidth) / 2)
                    .padding(.top, trackInset)

                // the thumb: the loaded window, in a hand-sized hit target
                RoundedRectangle(cornerRadius: barWidth / 2)
                    .fill(themeManager.currentTheme.accentColor)
                    .frame(width: barWidth, height: thumbLength)
                    .frame(width: PointsLeaderboardIndicator.thumbWidth)
                    .contentShape(Rectangle())
                    .opacity(isSeeking && !isDragging ? 0.6 : 1)
                    .padding(.top, trackInset)
                    .offset(y: offset)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let start = dragStartOffset ?? offset
                                if dragStartOffset == nil {
                                    dragStartOffset = offset
                                }
                                isDragging = true
                                showLabel()
                                let rank = PointsLeaderboardIndicator.rank(
                                    thumbOffset: start + value.translation.height,
                                    total: total,
                                    trackLength: trackLength,
                                    thumbLength: thumbLength
                                )
                                if rank != position {
                                    onDrag(rank)
                                }
                            }
                            .onEnded { _ in
                                isDragging = false
                                dragStartOffset = nil
                                fadeLabel()
                                onSeek(position)
                            }
                    )
                    .accessibilityElement(children: .ignore)
                    .accessibilityIdentifier("leaderboard.position.thumb")
                    .accessibilityLabel(Text("Leaderboard position"))
                    .accessibilityValue(Text(accessibilityValue))
                    .accessibilityAdjustableAction { direction in
                        let step: Int
                        switch direction {
                        case .increment:
                            step = 1
                        case .decrement:
                            step = -1
                        @unknown default:
                            step = 0
                        }
                        if step != 0 {
                            onSeek(PointsLeaderboardIndicator.steppedRank(position, total: total, direction: step))
                        }
                    }

                if labelShown {
                    dragLabel
                        .frame(height: labelHeight)
                        .padding(.trailing, PointsLeaderboardIndicator.thumbWidth + 4)
                        .padding(.top, trackInset)
                        .offset(y: offset + thumbLength / 2 - labelHeight / 2)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topTrailing)
        }
        .frame(width: PointsLeaderboardIndicator.thumbWidth)
        .onDisappear {
            labelFade?.cancel()
        }
    }

    /// the rank with the tier beneath it, beside the thumb
    private var dragLabel: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(PointsLeaderboardIndicator.rankText(position))
                .font(themeManager.currentTheme.bodyFont)
                .fontWeight(.bold)
                .foregroundStyle(themeManager.currentTheme.textColor)
            if let tier = tierText {
                Text(tier)
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundStyle(themeManager.currentTheme.textMutedColor)
            }
        }
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(themeManager.currentTheme.tintedBackgroundBase)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(themeManager.currentTheme.borderBaseColor, lineWidth: 1)
        )
        .cornerRadius(10)
        .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
    }

    /// "Top 5%" for the top tiers, "Everyone else" below them, nothing while
    /// the population is unknown
    private var tierText: String? {
        guard let parts = label(position) else {
            return nil
        }
        switch parts.tier {
        case Int(SdkPointsLeaderboardTierRest):
            return String(localized: "Everyone else")
        case Int(SdkPointsLeaderboardTierUnknown):
            return nil
        default:
            return String(format: String(localized: "Top %@%%"), String(parts.tierPercent))
        }
    }

    private var accessibilityValue: String {
        let rank = PointsLeaderboardIndicator.rankText(position)
        if let tier = tierText {
            return rank + ", " + tier
        }
        return rank
    }

    private func showLabel() {
        labelFade?.cancel()
        labelFade = nil
        if !labelShown {
            withAnimation(.easeOut(duration: 0.15)) {
                labelShown = true
            }
        }
    }

    /// the label lingers a moment after release so the landing rank can be read
    private func fadeLabel() {
        labelFade?.cancel()
        labelFade = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            if Task.isCancelled {
                return
            }
            withAnimation(.easeOut(duration: 0.3)) {
                labelShown = false
            }
        }
    }
}

private struct PointsHeader: View {
    @EnvironmentObject var themeManager: ThemeManager

    @ObservedObject var store: PointsLeaderboardStore
    let ownName: String
    let onEditEmoji: () -> Void

    var body: some View {
        let ownRow = store.me?.row

        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                // identity: the network's own name with the pencil that opens
                // the editor on the first line, the emoji tag on its own line
                // below it, then the ranked count; the rows stack name over tag
                // the same way
                HStack(spacing: 10) {
                    Text(ownName)
                        .font(themeManager.currentTheme.bodyFontLarge)
                        .fontWeight(.bold)
                        .foregroundStyle(themeManager.currentTheme.textColor)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Button(action: onEditEmoji) {
                        Image(systemName: "pencil")
                            .foregroundStyle(themeManager.currentTheme.textMutedColor)
                            .frame(width: 40, height: 40)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(store.emojiTag.isEmpty ? Text("Add emoji") : Text("Edit emoji"))
                }
                if !store.emojiTag.isEmpty {
                    Text(store.emojiTag)
                        .font(.system(size: 28))
                        .lineLimit(1)
                        .padding(.top, 4)
                }
                if store.totalRanked > 0 {
                    Text(String(format: String(localized: "%@ ranked networks"), SdkFormatPoints(Double(store.totalRanked))))
                        .font(themeManager.currentTheme.secondaryBodyFont)
                        .foregroundStyle(themeManager.currentTheme.textMutedColor)
                        .padding(.top, 4)
                }

                Spacer().frame(height: 16)

                // the three dimensions, each with its own rank
                HStack(alignment: .top, spacing: 8) {
                    PointsStatTile(
                        label: "Points",
                        value: ownRow?.totalPointsText ?? "-",
                        rank: ownRow?.rankPointsText ?? "-",
                        emphasized: store.sort == SdkPointsLeaderboardSortPoints
                    )
                    PointsStatTile(
                        label: "Blocks",
                        value: ownRow?.blocksWithPointsText ?? "-",
                        rank: ownRow?.rankBlocksText ?? "-",
                        emphasized: store.sort == SdkPointsLeaderboardSortBlocks
                    )
                    PointsStatTile(
                        label: "Streak",
                        value: ownRow?.streakText ?? "-",
                        rank: ownRow?.rankStreakText ?? "-",
                        emphasized: store.sort == SdkPointsLeaderboardSortStreak
                    )
                }

                if let ownRow {
                    Spacer().frame(height: 8)
                    HStack(spacing: 0) {
                        Text("Longest streak")
                        Text(verbatim: ": \(ownRow.longestStreakText)")
                    }
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundStyle(themeManager.currentTheme.textMutedColor)
                }

                Spacer().frame(height: 16)
                Divider()
                    .background(themeManager.currentTheme.borderBaseColor)
                Spacer().frame(height: 16)

                UrSwitchToggle(
                    isOn: Binding(
                        get: { store.isPointsPublic },
                        set: { _ in store.togglePointsPublic() }
                    ),
                    isEnabled: !store.isSettingPublic
                ) {
                    Text("Show my network name")
                        .font(themeManager.currentTheme.bodyFont)
                        .foregroundStyle(themeManager.currentTheme.textColor)
                }

                if !store.isPointsPublic {
                    Spacer().frame(height: 8)
                    Text("Your network appears as Anonymous until you turn this on.")
                        .font(themeManager.currentTheme.secondaryBodyFont)
                        .foregroundStyle(themeManager.currentTheme.textMutedColor)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(themeManager.currentTheme.tintedBackgroundBase)
            .cornerRadius(12)

            Spacer().frame(height: 16)

            Text("All-time points. A block is one finalized epoch; the streak counts consecutive blocks with points, ending at the latest one.")
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundStyle(themeManager.currentTheme.textMutedColor)

            Spacer().frame(height: 16)
        }
        .padding(.horizontal)
        .padding(.top)
    }
}

private struct PointsStatTile: View {
    @EnvironmentObject var themeManager: ThemeManager

    let label: LocalizedStringKey
    let value: String
    let rank: String
    let emphasized: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundStyle(themeManager.currentTheme.textMutedColor)
            Text(value)
                .font(themeManager.currentTheme.titleCondensedFont)
                .foregroundStyle(themeManager.currentTheme.textColor)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(rank)
                .font(themeManager.currentTheme.secondaryBodyFont)
                .fontWeight(.bold)
                .foregroundStyle(emphasized ? .urGreen : themeManager.currentTheme.textMutedColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(emphasized ? Color.urGreen.opacity(0.18) : themeManager.currentTheme.borderBaseColor)
                .cornerRadius(6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PointsSortChips: View {
    let sort: String
    let setSort: (String) -> Void

    var body: some View {
        Picker(
            "",
            selection: Binding(
                get: { sort },
                set: { setSort($0) }
            )
        ) {
            Text("Points").tag(SdkPointsLeaderboardSortPoints)
            Text("Blocks").tag(SdkPointsLeaderboardSortBlocks)
            Text("Streak").tag(SdkPointsLeaderboardSortStreak)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal)
        .padding(.bottom, 16)
    }
}

private struct PointsRow: View {
    @EnvironmentObject var themeManager: ThemeManager

    let row: PointsLeaderboardRowItem
    let sort: String
    let isNetworkRow: Bool

    private var rank: String {
        switch sort {
        case SdkPointsLeaderboardSortBlocks:
            return row.rankBlocksText
        case SdkPointsLeaderboardSortStreak:
            return row.rankStreakText
        default:
            return row.rankPointsText
        }
    }

    private var nameColor: Color {
        if isNetworkRow {
            return .urGreen
        }
        if row.anonymous {
            return themeManager.currentTheme.textMutedColor
        }
        return themeManager.currentTheme.textColor
    }

    var body: some View {
        HStack(spacing: 0) {
            Text(rank)
                .font(themeManager.currentTheme.bodyFont)
                .fontWeight(isNetworkRow ? .heavy : .regular)
                .foregroundStyle(isNetworkRow ? .urGreen : themeManager.currentTheme.textMutedColor)
                .frame(width: 56, alignment: .leading)
                .lineLimit(1)

            // identity cell: the name on the first line, the emoji tag on its
            // own line below it, so a long tag never squeezes the name on a
            // narrow screen (the own-stats header stacks name over tag the same way)
            VStack(alignment: .leading, spacing: 2) {
                if row.anonymous || row.displayName.isEmpty {
                    // the caller's own row reads Anonymous like everyone else's until the
                    // network opts in; only the highlight marks it
                    Text(String(localized: "Anonymous"))
                        .font(themeManager.currentTheme.bodyFont)
                        .fontWeight(isNetworkRow ? .heavy : .regular)
                        .foregroundStyle(nameColor)
                        .lineLimit(1)
                } else {
                    Text(row.displayName)
                        .font(themeManager.currentTheme.bodyFont)
                        .fontWeight(isNetworkRow ? .heavy : .regular)
                        .foregroundStyle(nameColor)
                        .lineLimit(1)
                }
                if !row.emojiTag.isEmpty {
                    Text(row.emojiTag)
                        .font(themeManager.currentTheme.bodyFont)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer().frame(width: 8)

            // the three values, the sorted one emphasized
            PointsRowValue(
                value: row.totalPointsText,
                emphasized: sort == SdkPointsLeaderboardSortPoints,
                isNetworkRow: isNetworkRow,
                width: 72
            )
            PointsRowValue(
                value: row.blocksWithPointsText,
                emphasized: sort == SdkPointsLeaderboardSortBlocks,
                isNetworkRow: isNetworkRow,
                width: 44
            )
            PointsRowValue(
                value: row.streakText,
                emphasized: sort == SdkPointsLeaderboardSortStreak,
                isNetworkRow: isNetworkRow,
                width: 44
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

private struct PointsRowValue: View {
    @EnvironmentObject var themeManager: ThemeManager

    let value: String
    let emphasized: Bool
    let isNetworkRow: Bool
    let width: CGFloat

    private var color: Color {
        if isNetworkRow {
            return .urGreen
        }
        if emphasized {
            return themeManager.currentTheme.textColor
        }
        return themeManager.currentTheme.textFaintColor
    }

    var body: some View {
        Text(value)
            .font(emphasized ? themeManager.currentTheme.bodyFont : themeManager.currentTheme.secondaryBodyFont)
            .fontWeight(isNetworkRow || emphasized ? .heavy : .regular)
            .foregroundStyle(color)
            .frame(width: width, alignment: .trailing)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }
}

private struct PointsFooter: View {
    @EnvironmentObject var themeManager: ThemeManager

    let rowCount: Int
    let isLoading: Bool
    let hasLoaded: Bool
    let errorMessage: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            if isLoading {
                ProgressView()
            } else if !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(themeManager.currentTheme.bodyFont)
                    .foregroundStyle(themeManager.currentTheme.textMutedColor)
                    .multilineTextAlignment(.center)
                Button(action: retry) {
                    Text("Retry")
                }
            } else if rowCount == 0 && hasLoaded {
                Text("No one is on the points leaderboard yet.")
                    .font(themeManager.currentTheme.bodyFont)
                    .foregroundStyle(themeManager.currentTheme.textMutedColor)
                    .multilineTextAlignment(.center)
            } else {
                Spacer().frame(height: 8)
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
    }
}
