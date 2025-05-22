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
    
    var leaderboardRank: Int
    var netProvidedFormatted: String
    var fetchLeaderboardData: () async -> Void
    var rankingPublic: Binding<Bool>
    var leaderboardEntries: [LeaderboardEntry]
    var isSettingRankingVisibility: Bool
    var isLoading: Bool
    
    var body: some View {
        
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
                    LeaderboardRow(leaderboardEntry: entry, rank: index + 1)
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
                leaderboardEntries: leaderboardEntries
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
                    .foregroundColor(themeManager.currentTheme.textColor)
                
                Spacer()
            }
            
            /**
             * Network Info
             */
            VStack(spacing: 0) {
                HStack {
                    Text("Current Ranking")
                        .font(themeManager.currentTheme.secondaryBodyFont)
                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                    Spacer()
                }
                
                HStack {
                    Text("#\(leaderboardRank)")
                        .font(themeManager.currentTheme.titleCondensedFont)
                        .foregroundColor(themeManager.currentTheme.textColor)
                    
                    Spacer()
                }
                
                Spacer().frame(height: 8)
                
                Divider()
                    .background(themeManager.currentTheme.borderBaseColor)
                
                Spacer().frame(height: 16)
                
                HStack {
                    Text("Net Provided")
                        .font(themeManager.currentTheme.secondaryBodyFont)
                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                    Spacer()
                }
                
                HStack {
                    Text(netProvidedFormatted)
                        .font(themeManager.currentTheme.titleCondensedFont)
                        .foregroundColor(themeManager.currentTheme.textColor)
                    
                    
                    Spacer()
                }

            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(themeManager.currentTheme.tintedBackgroundBase)
            .cornerRadius(12)
            
            Spacer().frame(height: 16)
            
            UrSwitchToggle(
                isOn: rankingPublic,
                isEnabled: !isSettingRankingVisibility
            ) {
                Text("Display network on leaderboard")
                    .font(themeManager.currentTheme.bodyFont)
            }
            .padding(.horizontal, 8)
                
        }
        .padding()
    }
    
}

private struct LeaderboardTable: View {
    
    @EnvironmentObject var themeManager: ThemeManager
    
    let tableData: [LeaderboardEntry]
    
    init(leaderboardEntries: [LeaderboardEntry]) {
        self.tableData = leaderboardEntries
    }
    
    var body: some View {
        
        Table(tableData) {
            TableColumn("Rank") { row in
                Text(row.rank)
                    .foregroundColor(themeManager.currentTheme.textMutedColor)
            }
            .width(32)
            TableColumn("Name") { row in
                Text(row.networkName)
                    .foregroundColor(themeManager.currentTheme.textColor)
            }
            TableColumn("Data Provided") { row in
                Text(row.netProvided)
                    .foregroundColor(themeManager.currentTheme.textColor)
            }
        }
    }
    
    
}

private struct LeaderboardRow: View {
    
    @EnvironmentObject var themeManager: ThemeManager
    
    var leaderboardEntry: LeaderboardEntry
    var rank: Int
    
    var body: some View {
        VStack(spacing: 0) {
            
            Divider()
         
            HStack {
                
                HStack {
                    Text("#\(rank)")
                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                        .font(themeManager.currentTheme.bodyFont)
                        .frame(width: 36)
                    
                    Text(leaderboardEntry.networkName)
                        .font(themeManager.currentTheme.bodyFont)
                    
                }
                
                Spacer()
                
                Text(leaderboardEntry.netProvided)
                    .font(themeManager.currentTheme.bodyFont)
                
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            
        }
    }
    
}

//#Preview {
//    LeaderboardView()
//}
