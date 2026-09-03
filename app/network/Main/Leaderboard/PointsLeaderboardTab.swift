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

    @State private var showEmojiSheet: Bool = false
    @State private var emojiSaveError: String? = nil

    private var ownNetworkId: String? {
        if let id = store.me?.row?.networkId, !id.isEmpty {
            return id
        }
        return deviceManager.parsedJwt?.networkId?.idStr
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                PointsHeader(
                    store: store,
                    onEditEmoji: {
                        emojiSaveError = nil
                        showEmojiSheet = true
                    }
                )

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
                        // ask for the next page when a row near the end shows
                        if PointsLeaderboardPaging.shouldLoadMore(
                            lastVisibleRowIndex: index,
                            rowCount: store.rows.count,
                            isLoading: store.isLoading,
                            isEndReached: store.isEndReached
                        ) {
                            store.loadMore()
                        }
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
}

private struct PointsHeader: View {
    @EnvironmentObject var themeManager: ThemeManager

    @ObservedObject var store: PointsLeaderboardStore
    let onEditEmoji: () -> Void

    var body: some View {
        let ownRow = store.me?.row
        let ownName = ownRow.map { $0.displayName }.flatMap { $0.isEmpty ? nil : $0 }

        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                // identity line: the emoji tag, the network's own name, the
                // pencil that opens the editor
                HStack(spacing: 12) {
                    if !store.emojiTag.isEmpty {
                        Text(store.emojiTag)
                            .font(.system(size: 28))
                            .lineLimit(1)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ownName ?? "-")
                            .font(themeManager.currentTheme.bodyFontLarge)
                            .fontWeight(.bold)
                            .foregroundStyle(themeManager.currentTheme.textColor)
                            .lineLimit(1)
                        if store.totalRanked > 0 {
                            Text(String(format: String(localized: "%@ ranked networks"), SdkFormatPoints(Double(store.totalRanked))))
                                .font(themeManager.currentTheme.secondaryBodyFont)
                                .foregroundStyle(themeManager.currentTheme.textMutedColor)
                        }
                    }
                    Spacer(minLength: 0)
                    Button(action: onEditEmoji) {
                        Image(systemName: "pencil")
                            .foregroundStyle(themeManager.currentTheme.textMutedColor)
                            .frame(width: 40, height: 40)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(store.emojiTag.isEmpty ? Text("Add emoji") : Text("Edit emoji"))
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
                    Text("Show on the points leaderboard")
                        .font(themeManager.currentTheme.bodyFont)
                        .foregroundStyle(themeManager.currentTheme.textColor)
                }

                if !store.isPointsPublic {
                    Spacer().frame(height: 8)
                    Text("Only you can see this. Turn it on to appear on the leaderboard.")
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

            HStack(spacing: 6) {
                if !row.emojiTag.isEmpty {
                    Text(row.emojiTag)
                        .font(themeManager.currentTheme.bodyFont)
                        .lineLimit(1)
                }
                if row.anonymous || row.displayName.isEmpty {
                    Text("Anonymous")
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
                Spacer(minLength: 0)
            }

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
