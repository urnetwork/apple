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
    
    let data: [DailyDataUsage] = [
        .init(name: "Used", bytes: 20),
        .init(name: "Pending", bytes: 10),
        .init(name: "Available", bytes: 70),
    ]
    
    let cornerRadius: CGFloat = 12


    
    var body: some View {
        
        ZStack {
            Chart(data.indices, id: \.self) { index in // Get the Production values.
                
                let isFirst = index == 0
                let isLast = index == (data.count - 1)
                
                BarMark(
                    x: .value("Data", data[index].bytes)
                )
                .foregroundStyle(by: .value("Name", data[index].name))
                .clipShape(
                    UnevenRoundedRectangle(
                        cornerRadii: RectangleCornerRadii(
                            topLeading: isFirst ? cornerRadius : 0,
                            bottomLeading: isFirst ? cornerRadius : 0,
                            bottomTrailing: isLast ? cornerRadius : 0,
                            topTrailing: isLast ? cornerRadius : 0
                        )
                    )
                )
//                .annotation(position: .bottom) {
//                    // Display the actual bytes directly below each bar segment
//                    Text("\(data[index].bytes)%")
//                        .font(.caption)
//                        .foregroundColor(.primary)
//                }
                
            }
//            .chartXAxis {
//                // Custom axis that only shows the used bytes value
//                AxisMarks(position: .bottom) {
//                    AxisValueLabel {
//                        Text(ByteCountFormatter().string(fromByteCount: usedBytes))
//                    }
//                }
//            }
            .chartXAxis(.hidden)
            .frame(height: 32)
            .chartForegroundStyleScale([
                "Used": .urElectricBlue, "Pending": .urCoral, "Available": themeManager.currentTheme.textFaintColor
            ])
        }
        .padding(.horizontal)
        
    }
}

#Preview {
    UsageBar()
}
