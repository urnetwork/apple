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
    let total: Int = 5
    let cornerRadius: CGFloat = 12
    
    init(referralCount: Int) {
        
        let cappedCount = min(referralCount, total)
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
//        .chartXScale(domain: 0...5)
        .chartXAxis {
            AxisMarks(values: Array(0...5)) { value in
                AxisGridLine()
                AxisTick()
                AxisValueLabel()
            }
        }
//        .chartXAxis(.hidden)
//        .frame(height: 32)
        .frame(height: 44)
        .chartForegroundStyleScale([
            "Referrals": .urElectricBlue, "Available": themeManager.currentTheme.textFaintColor
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
