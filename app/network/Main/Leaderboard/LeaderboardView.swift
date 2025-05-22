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
                    leaderboardRank: viewModel.networkRanking?.leaderboardRank ?? 0,
                    netMiBProvided: viewModel.networkRanking?.netMiBCount ?? 0,
                    fetchLeaderboardData: viewModel.fetchLeaderboardData,
                    rankingPublic: $viewModel.networkRankingPublic,
                    leaderboardEntries: viewModel.leaderboardEarners,
                    isSettingRankingVisibility: viewModel.isSettingRankingVisibility
                )
                
            }
            
        }
        .frame(maxWidth: .infinity)
        
    }
}

private struct LeaderboardViewPopulated: View {
    
    @EnvironmentObject var themeManager: ThemeManager
    
    var leaderboardRank: Int
    var netMiBProvided: Float
    var fetchLeaderboardData: () async -> Void
    var rankingPublic: Binding<Bool>
    var leaderboardEntries: [LeaderboardEntry]
    var isSettingRankingVisibility: Bool
    
    var body: some View {
        
        ScrollView {
            
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
                        Text(String(leaderboardRank))
                            .font(themeManager.currentTheme.titleCondensedFont)
                            .foregroundColor(themeManager.currentTheme.textColor)
                        
                        Spacer()
                    }
                    
                    Spacer().frame(height: 8)
                    
                    Divider()
                        .background(themeManager.currentTheme.borderBaseColor)
                    
                    Spacer().frame(height: 16)
                    
                    HStack {
                        Text("Net MiB Provided")
                            .font(themeManager.currentTheme.secondaryBodyFont)
                            .foregroundColor(themeManager.currentTheme.textMutedColor)
                        Spacer()
                    }
                    
                    HStack {
                        Text(String(netMiBProvided))
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
            
            #if os(iOS)
            LazyVStack(spacing: 0) {
             
                ForEach(Array(leaderboardEntries.enumerated()), id: \.offset) { index, entry in
                    LeaderboardRow(leaderboardEntry: entry, rank: index + 1)
                }
                
            }
            #endif
            
            #if os(macOS)
            LeaderboardTable(
                leaderboardEntries: leaderboardEntries
            )
            #endif
            
            
        }
        .refreshable {
            await fetchLeaderboardData()
        }
        
    }
    
}

private struct LeaderboardTable: View {
    
    @EnvironmentObject var themeManager: ThemeManager
    
//    #if os(iOS)
//    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
//    private var isCompact: Bool { horizontalSizeClass == .compact }
//    #else
//    private let isCompact = false
//    #endif
    
    // var leaderboardEntries: [SdkLeaderboardEarner]
    // let tableData = Array(leaderboardEntries.enumerated())
    // let tableData: [SdkLeaderboardEarner]
    let tableData: [LeaderboardEntry]
    
    init(leaderboardEntries: [LeaderboardEntry]) {
        // self.leaderboardEntries = leaderboardEntries
        // self.tableData = Array(leaderboardEntries)
        self.tableData = leaderboardEntries
    }
    
    var body: some View {
        
//        let rows = tableData.enumerated().map { index, entry in
//            LeaderboardTableRow(
//                networkName: entry.isPublic ? entry.networkName : "Private Network",
//                netProvided: formatFileSize(mib: entry.netMiBCount),
//                rank: index + 1
//            )
//        }
        
//        Table(tableData, id: \.offset) {
//            TableColumn("Rank") { index, _ in
//                Text("#\(index.offset + 1)")
//                    .foregroundColor(themeManager.currentTheme.textMutedColor)
//            }
//            .width(50)
//            
//            TableColumn("Network") { _, entry in
//                if (entry.isPublic) {
//                    Text(entry.networkName)
//                } else {
//                    Text("Private Network")
//                        .foregroundColor(themeManager.currentTheme.textMutedColor)
//                }
//            }
//            
//            TableColumn("Provided") { _, entry in
//                Text(formatFileSize(mib: entry.netMiBCount))
//                    .font(themeManager.currentTheme.bodyFont)
//            }
//            .width(120)
//        }
        
        Table(tableData) {
            TableColumn("Rank") { row in
                Text(row.rank)
                    .foregroundColor(themeManager.currentTheme.textMutedColor)
            }
            .width(50)
            TableColumn("Name") { row in
                Text(row.networkName)
                    .foregroundColor(themeManager.currentTheme.textColor)
            }
            TableColumn("Data Provided") { row in
                Text(row.netProvided)
                    .foregroundColor(themeManager.currentTheme.textColor)
            }
            .width(120)
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
