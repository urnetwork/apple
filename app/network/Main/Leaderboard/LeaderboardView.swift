//
//  LeaderboardView.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2025/05/21.
//

import SwiftUI
import URnetworkSdk

/// The leaderboard's tabs, in the picker's order: the Protocol board, the
/// SN25-aligned Top 200 projection (apple/LEADERTOP.md, Q14), first and the
/// default; the all-time points leaderboard (android/POINTSLEADERBOARD.md);
/// and the last-4-payments data leaderboard, frozen since 2026-10-06.
enum LeaderboardTab: String, CaseIterable {
    case `protocol`
    case points
    case data

    /// the tab the leaderboard opens on
    static let initial: LeaderboardTab = .protocol
}

/// The scroll id of a leaderboard list's top (its header): the tab reset's target.
enum LeaderboardListAnchor: Hashable {
    case top
}

struct LeaderboardView: View {
    
    @EnvironmentObject var themeManager: ThemeManager
    // a regular-width window shows the network's own standing beside the
    // ranking instead of above it
    @Environment(\.isRegularWidth) private var isRegularWidth
    
    @StateObject private var viewModel: ViewModel
    
    // the points tab's store lives as long as the leaderboard does, so a
    // switch to Data and back keeps the opt-in and tag the user just set;
    // the sdk controller itself is open only while the Points tab shows
    @StateObject private var pointsStore = PointsLeaderboardStore()

    // the Protocol board lives as long as the leaderboard does, so a switch
    // to another tab and back keeps its pages
    @StateObject private var protocolStore = ProtocolTopStore()

    @EnvironmentObject var deepLinkRouter: DeepLinkRouter

    @State private var selectedTab: LeaderboardTab = .initial
    
    // every tap on the picker, the selected tab included, scrolls the shown
    // list back to its top (mmm/DESIGNSTYLE.md, "Long ranked lists"): the
    // tap itself is counted and the lists watch the count
    @State private var scrollResetToken: Int = 0
    
    init(api: UrApiServiceProtocol) {
        _viewModel = .init(wrappedValue: .init(apiService: api))
    }
    
    /// a tap on a tab: show it (a switch recreates the list at its top) and
    /// count the tap so a re-tap scrolls the shown list to its top
    private func selectTab(_ tab: LeaderboardTab) {
        selectedTab = tab
        scrollResetToken += 1
    }
    
    var body: some View {
        
        NavigationStack {

            GeometryReader { geometry in

                let panes = SplitLayout.panes(size: geometry.size, sideBySide: true, fold: geometry.windowFold)

                ZStack {

                    // the ranking stays this one view whatever the width, so
                    // its tab and its place in the list carry over a resize
                    ranking
                        // compact: the picker and the ranked list share the
                        // readable column; regular: the left pane
                        .frame(maxWidth: isRegularWidth ? panes.firstEnd : TabletLayout.contentWidth)
                        .frame(maxWidth: .infinity, alignment: isRegularWidth ? .leading : .center)

                    if isRegularWidth {
                        secondPane
                        .frame(width: geometry.size.width - panes.secondStart)
                        .overlay(alignment: .leading) {
                            Rectangle()
                                .fill(themeManager.currentTheme.borderBaseColor)
                                .frame(width: 1)
                                .ignoresSafeArea()
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }

                }
            }
            .background(themeManager.currentTheme.backgroundColor.ignoresSafeArea())
            .navigationTitle("Leaderboard")
            
        }
        // the Earnings Top 200 tile's "See the Protocol leaderboard"
        .onReceive(deepLinkRouter.$pendingLeaderboardProtocol) { pending in
            guard pending, deepLinkRouter.consumeLeaderboardProtocol() else { return }
            selectTab(.protocol)
        }
    }

    /// Beside the ranking in a regular-width window: the Protocol board's
    /// banner, own-status card and explainer, or the network's own standing
    /// beside the Points and Data rankings.
    @ViewBuilder
    private var secondPane: some View {
        if selectedTab == .protocol {
            ProtocolSidePane(
                store: protocolStore,
                pointsStore: pointsStore,
                claimOnEarnings: claimOnEarnings
            )
        } else {
            LeaderboardOwnNetwork(
                leaderboardRank: viewModel.networkRank,
                netProvidedFormatted: viewModel.netProvidedFormatted,
                rankingPublic: $viewModel.networkRankingPublic,
                isSettingRankingVisibility: viewModel.isSettingRankingVisibility,
                pointsStore: pointsStore
            )
        }
    }

    /// Claim on Earnings: Account › Earnings at its Top 200 tile.
    private func claimOnEarnings() {
        deepLinkRouter.openEarningsTop200()
    }

    /// The tab picker over the Protocol, Points or Data ranking. The
    /// Protocol and Data rankings lead with the network's own standing
    /// unless it shows beside it.
    private var ranking: some View {
        
        VStack(spacing: 0) {
            
            Picker("", selection: $selectedTab) {
                Text("Protocol").tag(LeaderboardTab.protocol)
                Text("Points").tag(LeaderboardTab.points)
                Text("Data").tag(LeaderboardTab.data)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("leaderboard.tab.picker")
            .overlay {
                // the taps are taken over the native control: its binding
                // is silent for a re-tap and a SwiftUI gesture laid over
                // it never fires, so each half selects its tab and counts
                // the tap; assistive tech still drives the picker itself
                HStack(spacing: 0) {
                    ForEach(LeaderboardTab.allCases, id: \.self) { tab in
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectTab(tab)
                            }
                    }
                }
                .accessibilityHidden(true)
            }
            .padding(.horizontal)
            .padding(.top, 8)
            
            switch selectedTab {
            case .protocol:
                /**
                 * Protocol: the SN25-aligned Top 200 projection
                 */

                ProtocolLeaderboardTab(
                    store: protocolStore,
                    pointsStore: pointsStore,
                    scrollResetToken: scrollResetToken,
                    showsStatus: !isRegularWidth,
                    isWide: isRegularWidth,
                    claimOnEarnings: claimOnEarnings
                )

            case .points:
                /**
                 * Points: the all-time points leaderboard
                 */
                
                PointsLeaderboardTab(store: pointsStore, scrollResetToken: scrollResetToken)
                
            case .data:
                if (viewModel.isInitializing) {
                    /**
                     * Initializing
                     */
                    
                    VStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    
                } else {
                    /**
                     * Leaderboard initialized
                     */
                    
                    LeaderboardViewPopulated(
                        leaderboardRank: viewModel.networkRank,
                        netProvidedFormatted: viewModel.netProvidedFormatted,
                        fetchLeaderboardData: viewModel.fetchLeaderboardData,
                        rankingPublic: $viewModel.networkRankingPublic,
                        leaderboardEntries: viewModel.leaderboardEarners,
                        isSettingRankingVisibility: viewModel.isSettingRankingVisibility,
                        isLoading: viewModel.isLoading,
                        scrollResetToken: scrollResetToken,
                        showsOwnStanding: !isRegularWidth
                    )
                    
                }
            }

        }
    }
}

private struct LeaderboardViewPopulated: View {
    
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var deviceManager: DeviceManager
    
    var leaderboardRank: Int
    var netProvidedFormatted: String
    var fetchLeaderboardData: () async -> Void
    var rankingPublic: Binding<Bool>
    var leaderboardEntries: [LeaderboardEntry]
    var isSettingRankingVisibility: Bool
    var isLoading: Bool
    /// bumped by the tab picker on every tap: the list scrolls to its top
    var scrollResetToken: Int = 0
    /// the network's own standing heads the list, unless it shows beside it
    var showsOwnStanding: Bool = true
    
    var body: some View {
        
        let networkId = deviceManager.parsedJwt?.networkId
        
        ScrollViewReader { proxy in
            
            ScrollView {
                
                VStack(spacing: 0) {
                    if showsOwnStanding {
                        LeaderboardHeader(
                            leaderboardRank: leaderboardRank,
                            netProvidedFormatted: netProvidedFormatted,
                            rankingPublic: rankingPublic,
                            isSettingRankingVisibility: isSettingRankingVisibility
                        )
                    } else {
                        Spacer().frame(height: 8)
                    }
                }
                .id(LeaderboardListAnchor.top)
                
                LazyVStack(spacing: 0) {
                 
                    ForEach(Array(leaderboardEntries.enumerated()), id: \.offset) { index, entry in
                        LeaderboardRow(
                            leaderboardEntry: entry,
                            rank: index + 1,
                            networkId: networkId
                        )
                    }
                    
                }
                
            }
            .onChange(of: scrollResetToken) { _ in
                withAnimation {
                    proxy.scrollTo(LeaderboardListAnchor.top, anchor: .top)
                }
            }
            #if os(iOS)
            .refreshable {
                await fetchLeaderboardData()
            }
            #elseif os(macOS)
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button(action: {
                        Task {
                            await fetchLeaderboardData()
                        }
                    }) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isLoading)
                }
            }
            #endif
            
        }
        
    }
    
}

private struct LeaderboardHeader: View {
    
    @EnvironmentObject var themeManager: ThemeManager
    
    var leaderboardRank: Int
    var netProvidedFormatted: String
    var rankingPublic: Binding<Bool>
    var isSettingRankingVisibility: Bool
    /// the network's all-time points and longest streak, beside the ranking
    var pointsText: String? = nil
    var longestStreakText: String? = nil
    
    var body: some View {
        VStack(alignment: .leading) {
            
            /**
             * Network Info
             */
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Current Ranking")
                        .font(themeManager.currentTheme.secondaryBodyFont)
                        .foregroundStyle(themeManager.currentTheme.textMutedColor)
                    Spacer()
                }
                
                HStack {
                    Text(leaderboardRank > 0 ? "#\(leaderboardRank)" : "-")
                        .font(themeManager.currentTheme.titleCondensedFont)
                        .foregroundStyle(themeManager.currentTheme.textColor)
                    
                    Spacer()
                }
                
                Spacer().frame(height: 8)
                
                Divider()
                    .background(themeManager.currentTheme.borderBaseColor)
                
                Spacer().frame(height: 16)
                
                HStack {
                    Text("Net Provided")
                        .font(themeManager.currentTheme.secondaryBodyFont)
                        .foregroundStyle(themeManager.currentTheme.textMutedColor)
                    Spacer()
                }
                
                HStack {
                    Text(netProvidedFormatted)
                        .font(themeManager.currentTheme.titleCondensedFont)
                        .foregroundStyle(themeManager.currentTheme.textColor)
                    
                    
                    Spacer()
                }
                
                Spacer().frame(height: 8)
                
                Divider()
                    .background(themeManager.currentTheme.borderBaseColor)
                
                Spacer().frame(height: 16)

                if let pointsText {
                    standingRow("Points", value: pointsText)
                }

                if let longestStreakText {
                    standingRow("Longest streak", value: longestStreakText)
                }
                
                Toggle(isOn: rankingPublic) {
                    Text("Display network on leaderboard")
                        .font(themeManager.currentTheme.bodyFont)
                }
                .disabled(isSettingRankingVisibility)

            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(themeManager.currentTheme.tintedBackgroundBase)
            .cornerRadius(12)
            
            Spacer().frame(height: 16)
            
            Text("The leaderboard is the sum of the last 4 payments. It is updated each payment cycle.")
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundStyle(themeManager.currentTheme.textMutedColor)
                
        }
        .padding()
    }

    /// A label over its value and a divider, as the rank and net provided are.
    private func standingRow(_ label: LocalizedStringKey, value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label)
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundStyle(themeManager.currentTheme.textMutedColor)

            Text(value)
                .font(themeManager.currentTheme.titleCondensedFont)
                .foregroundStyle(themeManager.currentTheme.textColor)

            Spacer().frame(height: 8)

            Divider()
                .background(themeManager.currentTheme.borderBaseColor)

            Spacer().frame(height: 16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
}

/**
 * "Your network" beside the ranking in a regular-width window: the network's
 * data leaderboard rank and net provided, its all-time points and longest
 * streak, and whether it shows on the leaderboard. It holds the points
 * controller open while it shows, whichever tab the ranking has.
 */
private struct LeaderboardOwnNetwork: View {

    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var deviceManager: DeviceManager

    var leaderboardRank: Int
    var netProvidedFormatted: String
    var rankingPublic: Binding<Bool>
    var isSettingRankingVisibility: Bool
    @ObservedObject var pointsStore: PointsLeaderboardStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                Text("Your network")
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundStyle(themeManager.currentTheme.textMutedColor)
                    .padding(.horizontal)
                    .padding(.top)

                LeaderboardHeader(
                    leaderboardRank: leaderboardRank,
                    netProvidedFormatted: netProvidedFormatted,
                    rankingPublic: rankingPublic,
                    isSettingRankingVisibility: isSettingRankingVisibility,
                    pointsText: pointsStore.me?.row?.totalPointsText ?? "-",
                    longestStreakText: pointsStore.me?.row?.longestStreakText ?? "-"
                )

            }
            .frame(maxWidth: TabletLayout.contentWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            pointsStore.open(.ownNetwork, device: deviceManager.device, api: deviceManager.api)
        }
        .onReceive(deviceManager.$device) { device in
            pointsStore.deviceChanged(device: device, api: deviceManager.api)
        }
        .onDisappear {
            pointsStore.close(.ownNetwork)
        }
    }
}

private struct LeaderboardRow: View {
    
    @EnvironmentObject var themeManager: ThemeManager
    // @EnvironmentObject var deviceManager: DeviceManager
    
    var leaderboardEntry: LeaderboardEntry
    var rank: Int
    var networkId: SdkId?
    var isNetworkRow: Bool
    
    init(leaderboardEntry: LeaderboardEntry, rank: Int, networkId: SdkId?) {
        self.leaderboardEntry = leaderboardEntry
        self.rank = rank
        self.networkId = networkId
        
        self.isNetworkRow = networkId?.idStr == leaderboardEntry.networkId
    }
    
    
    var body: some View {
        
        VStack(spacing: 0) {
            
            Divider()
         
            HStack {
                
                HStack(spacing: 0) {
                    
                    Text("#\(rank)")
                        .foregroundStyle(
                            isNetworkRow
                                ? .urGreen
                                : themeManager.currentTheme.textMutedColor
                        )
                        .font(themeManager.currentTheme.bodyFont)
                        .frame(width: 42)
                    
                    Text(leaderboardEntry.networkName)
                        .font(themeManager.currentTheme.bodyFont)
                        .foregroundStyle(
                            isNetworkRow
                            ? .urGreen // is network, highlight
                            : leaderboardEntry.isPublic // not your network, check if is public
                                ? themeManager.currentTheme.textColor // public
                                : themeManager.currentTheme.textMutedColor // private - muted color
                        )
                    
                }
                
                Spacer()
                
                Text(leaderboardEntry.netProvided)
                    .font(themeManager.currentTheme.bodyFont)
                    .foregroundStyle(
                        isNetworkRow
                            ? .urGreen
                            : themeManager.currentTheme.textColor
                    )
                
            }
            .padding(.trailing, 16)
            .padding(.vertical, 8)
            
        }
    }
    
}

//#Preview {
//    LeaderboardView(api: MockUrApiService())
//}
