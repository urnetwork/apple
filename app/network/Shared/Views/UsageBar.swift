//
//  UsageBar.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 7/24/25.
//

import SwiftUI
import Charts

struct DailyDataUsage: Identifiable {
    
    var name: String
    var bytes: Int
    
    var id = UUID()
}

struct UsageBar: View {
    
    @EnvironmentObject var themeManager: ThemeManager
    
    let data: [DailyDataUsage]
    let totalBytes: Int
    
    init(availableByteCount: Int, pendingByteCount: Int, usedByteCount: Int) {
        self.data = [
            .init(name: "Used", bytes: usedByteCount),
            .init(name: "Pending", bytes: pendingByteCount),
            .init(name: "Available", bytes: availableByteCount),
        ]
        self.totalBytes = availableByteCount + pendingByteCount + usedByteCount
    }
    
    func minNonZeroValue(_ bytes: Int) -> Int {
        
        let minVal = Double(self.totalBytes) * 0.015 // enforce 1.5% so it shows up in the bar
        
        if bytes == 0 {
            // if empty, don't display the bar at all
            return 0
        } else if bytes < Int(minVal) {
            // ensure it takes up min % of bar
            return Int(minVal)
        } else {
            // larger than min value, display as is
            return bytes
        }
        
    }
    
    func getCornerRadii(_ index: Int) -> RectangleCornerRadii {
        
        
        // check if bar is full bar
        // is full bar, round everything
        if self.data[index].bytes == self.totalBytes {
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
        if index == (data.count - 1) {
            // not a full bar
            // round only trailing
            return RectangleCornerRadii(
                topLeading: 0,
                bottomLeading: 0,
                bottomTrailing: cornerRadius,
                topTrailing: cornerRadius
            )
        
        }
        
        // handle pending
        return RectangleCornerRadii(
            topLeading: self.data[0].bytes == 0 ? cornerRadius : 0, // round if used is 0
            bottomLeading: self.data[0].bytes == 0 ? cornerRadius : 0, // round if used is 0
            bottomTrailing: self.data[data.count - 1].bytes == 0 ? cornerRadius : 0, // round if available is 0
            topTrailing: self.data[data.count - 1].bytes == 0 ? cornerRadius : 0, // round if available is 0
        )
        
    }
    
    let cornerRadius: CGFloat = 12
    
    var body: some View {
        
        ZStack {
            Chart(data.indices, id: \.self) { index in // Get the Production values.
                   
                BarMark(
                    x: .value("Data", self.minNonZeroValue(data[index].bytes))
                )
                .foregroundStyle(by: .value("Name", data[index].name))
                .clipShape(
                    UnevenRoundedRectangle(
                        cornerRadii: getCornerRadii(index)
                    )
                )
                
            }
            .chartXAxis(.hidden)
            .frame(height: 32)
            .chartForegroundStyleScale([
                "Used": .urElectricBlue, "Pending": .urCoral, "Available": themeManager.currentTheme.textFaintColor
            ])
        }
        
    }
}

#Preview {
    UsageBar(
        availableByteCount: 70,
        pendingByteCount: 10,
        usedByteCount: 20
    )
}
