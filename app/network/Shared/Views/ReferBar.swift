//
//  ReferBar.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 9/26/25.
//

import SwiftUI
import Charts

struct ReferDataUsage: Identifiable {
    
    var name: String
    var count: Int
    
    var id = UUID()
}

struct ReferBar: View {
    
    @EnvironmentObject var themeManager: ThemeManager
    
    let data: [ReferDataUsage]
    let total: Int
    let cornerRadius: CGFloat = 12
    
    init(referralCount: Int, total: Int = referralMaxReferrals) {
        
        self.total = max(1, total)
        let cappedCount = min(referralCount, self.total)
        self.data = [
            .init(name: "Referrals", count: cappedCount),
            .init(name: "Available", count: total - cappedCount),
        ]
        
    }
    
    var body: some View {
        
        Chart(data.indices, id: \.self) { index in
               
            BarMark(
                x: .value("Data", self.data[index].count)
            )
            .foregroundStyle(by: .value("Name", data[index].name))
            .clipShape(
                UnevenRoundedRectangle(
                    cornerRadii: getCornerRadii(index)
                )
            )
            
        }
        // A plain filled bar like the other platforms: no axis, ticks or labels.
        // The 0...5 axis this replaced was a leftover from the first draft, when
        // the cap was hardcoded to 5; the cap now comes from the referral terms.
        .chartXScale(domain: 0...total)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: 12)
        .chartForegroundStyleScale([
            "Referrals": .urReferralGold, "Available": themeManager.currentTheme.textFaintColor
        ])
        
    }
    
    func getCornerRadii(_ index: Int) -> RectangleCornerRadii {
        
        // check if bar is full bar
        // is full bar, round everything
        if self.data[index].count == self.total || self.data[index].count == 0 {
            return RectangleCornerRadii(
                topLeading: cornerRadius,
                bottomLeading: cornerRadius,
                bottomTrailing: cornerRadius,
                topTrailing: cornerRadius
            )
        }
        
        // handle leading
        if index == 0 {
            // we already checked it's not a full bar
            // round only leading
            return RectangleCornerRadii(
                topLeading: cornerRadius,
                bottomLeading: cornerRadius,
                bottomTrailing: 0,
                topTrailing: 0
            )
        }
        
        // handle trailing
        return RectangleCornerRadii(
            topLeading: 0,
            bottomLeading: 0,
            bottomTrailing: cornerRadius,
            topTrailing: cornerRadius
        )
    }
}

//#Preview {
//    ReferBar()
//}
