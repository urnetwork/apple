//
//  LeaderboardEntry.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 7/5/25.
//

import Foundation

struct LeaderboardEntry: Identifiable {
    /**
     * This is used when passing LeaderboardEntry to lists/tables
     * ID needs to be unique. We're not using networkId, because it's an empty string if the user has their network marked as private.
     * Instead, we're using their rank, which is unique, from 0-99
     */
    let id: String
    
    let networkId: String
    let networkName: String
    let netProvided: String
    let rank: String
    let isPublic: Bool

    init(
        networkId: String,
        networkName: String,
        netProvided: String,
        rank: Int,
        isPublic: Bool,
        containsProfanity: Bool
    ) {

        self.id = "\(rank)"
        self.networkId = networkId

        self.networkName = !isPublic
            ? NSLocalizedString("Private Network", comment: "Network name when privacy is enabled")
            : containsProfanity
                ? String(networkName.prefix(1)) + String(repeating: "*", count: networkName.count - 2) + String(networkName.suffix(1))
                : networkName
        
        self.netProvided = netProvided
        self.rank = "\(rank + 1)"
        self.isPublic = isPublic
    }
}
