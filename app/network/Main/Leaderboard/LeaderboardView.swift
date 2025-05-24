//
//  LeaderboardView.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2025/05/21.
//

import SwiftUI
import URnetworkSdk

struct LeaderboardView: View {
    
    @EnvironmentObject var themeManager: ThemeManager
    
    @StateObject private var viewModel: ViewModel
    
    init(api: SdkApi) {
        _viewModel = .init(wrappedValue: .init(api: api))
    }
    
    var body: some View {
        
        Group {
            
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
                    isLoading: viewModel.isLoading
                )
                
            }
            
        }
        .frame(maxWidth: .infinity)
        
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
    
    var body: some View {
        
        let networkId = deviceManager.parsedJwt?.networkId
        
        #if os(iOS)
        
        ScrollView {
            
            LeaderboardHeader(
                leaderboardRank: leaderboardRank,
                netProvidedFormatted: netProvidedFormatted,
                rankingPublic: rankingPublic,
                isSettingRankingVisibility: isSettingRankingVisibility
            )
            
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
        .refreshable {
            await fetchLeaderboardData()
        }
        
        
        #elseif os(macOS)
        
        VStack {
            
            LeaderboardHeader(
                leaderboardRank: leaderboardRank,
                netProvidedFormatted: netProvidedFormatted,
                rankingPublic: rankingPublic,
                isSettingRankingVisibility: isSettingRankingVisibility
            )
            
            LeaderboardTable(
                leaderboardEntries: leaderboardEntries,
                networkId: networkId
            )
            
        }
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

private struct LeaderboardHeader: View {
    
    @EnvironmentObject var themeManager: ThemeManager
    
    var leaderboardRank: Int
    var netProvidedFormatted: String
    var rankingPublic: Binding<Bool>
    var isSettingRankingVisibility: Bool
    
    var body: some View {
        VStack{

            HStack {
                Text("Leaderboard")
                    .font(themeManager.currentTheme.titleFont)
                    .foregroundStyle(themeManager.currentTheme.textColor)
                
                Spacer()
            }
            
            /**
             * Network Info
             */
            VStack(spacing: 0) {
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
                
                UrSwitchToggle(
                    isOn: rankingPublic,
                    isEnabled: !isSettingRankingVisibility
                ) {
                    Text("Display network on leaderboard")
                        .font(themeManager.currentTheme.bodyFont)
                }

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

private struct LeaderboardTable: View {
    
    @EnvironmentObject var themeManager: ThemeManager
    
    let tableData: [LeaderboardEntry]
    let networkId: SdkId?
    
    init(leaderboardEntries: [LeaderboardEntry], networkId: SdkId?) {
        self.tableData = leaderboardEntries
        self.networkId = networkId
    }
    
    var body: some View {
        
        Table(tableData) {
            
            TableColumn("Rank") { row in
                
                let isNetworkRow = networkId?.idStr == row.networkId
                
                HStack {

                    Text("#\(row.rank)")
                        .foregroundStyle(
                            isNetworkRow
                                ? .urGreen
                                : themeManager.currentTheme.textMutedColor
                        )
                    
                }
            }
            .width(48)
            TableColumn("Name") { row in
                
                let isNetworkRow = networkId?.idStr == row.networkId
                
                Text(row.networkName)
                    .foregroundStyle(
                        isNetworkRow
                        ? .urGreen // is your network, highlight
                        : row.isPublic // check if is public
                            ? themeManager.currentTheme.textColor // is public
                            : themeManager.currentTheme.textMutedColor // is private - muted text color
                    )
            }
            TableColumn("Data Provided") { row in
                
                let isNetworkRow = networkId?.idStr == row.networkId
                
                Text(row.netProvided)
                    .foregroundStyle(
                        isNetworkRow
                            ? .urGreen
                            : themeManager.currentTheme.textColor
                    )
            }
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
//    LeaderboardView()
//}
