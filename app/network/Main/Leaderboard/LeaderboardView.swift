//
//  LeaderboardView.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2025/05/21.
//

import SwiftUI
import URnetworkSdk

/// The leaderboard's two tabs: the last-4-payments data leaderboard and the
/// all-time points leaderboard (android/POINTSLEADERBOARD.md).
enum LeaderboardTab: String, CaseIterable {
    case data
    case points
}

/// The scroll id of a leaderboard list's top (its header): the tab reset's target.
enum LeaderboardListAnchor: Hashable {
    case top
}

struct LeaderboardView: View {
    
    @EnvironmentObject var themeManager: ThemeManager
    
    @StateObject private var viewModel: ViewModel
    
    // the points tab's store lives as long as the leaderboard does, so a
    // switch to Data and back keeps the opt-in and tag the user just set;
    // the sdk controller itself is open only while the Points tab shows
    @StateObject private var pointsStore = PointsLeaderboardStore()
    
    @State private var selectedTab: LeaderboardTab = .data
    
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
            
            VStack(spacing: 0) {
                
                Picker("", selection: $selectedTab) {
                    Text("Data").tag(LeaderboardTab.data)
                    Text("Points").tag(LeaderboardTab.points)
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
                            scrollResetToken: scrollResetToken
                        )
                        
                    }
                }

            }
            // tablets: the picker and the ranked list share the readable column
            .tabletReadableColumn()
            .background(themeManager.currentTheme.backgroundColor.ignoresSafeArea())
            .navigationTitle("Leaderboard")
            
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
    
    var body: some View {
        
        let networkId = deviceManager.parsedJwt?.networkId
        
        ScrollViewReader { proxy in
            
            ScrollView {
                
                LeaderboardHeader(
                    leaderboardRank: leaderboardRank,
                    netProvidedFormatted: netProvidedFormatted,
                    rankingPublic: rankingPublic,
                    isSettingRankingVisibility: isSettingRankingVisibility
                )
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
