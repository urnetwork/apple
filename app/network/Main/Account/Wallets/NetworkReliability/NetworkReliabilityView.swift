//
//  NetworkReliabilityView.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 8/26/25.
//

import SwiftUI
import URnetworkSdk
import Charts

struct NetworkReliabilityView: View {
    
    @EnvironmentObject var themeManager: ThemeManager
    
    var reliabilityWindow: SdkReliabilityWindow?
    let reliabilityWeights: EnumeratedSequence<[Double]>
//    let clientCounts: EnumeratedSequence<[Int]>
    let totalClientCounts: EnumeratedSequence<[Int]>
    let mean: Double
    
    
    init(reliabilityWindow: SdkReliabilityWindow?) {
        
        if let reliabilityWeightsList = reliabilityWindow?.reliabilityWeights {
            
            let reliabilityWeightsArr = floatListToArray(reliabilityWeightsList)
            let sum = reliabilityWeightsArr.reduce(0, +)
            mean = sum / Double(reliabilityWeightsArr.count)
            
            reliabilityWeights = reliabilityWeightsArr.enumerated()
        } else {
            mean = 0
            reliabilityWeights = [Double]().enumerated()
        }
        
//        if let clientCountsList = reliabilityWindow?.clientCounts {
//            clientCounts = intListToArray(clientCountsList).enumerated()
//            print("intListToArray(clientCountsList): \(intListToArray(clientCountsList))")
//        } else {
//            print("clientCounts is empty")
//            clientCounts = [Int]().enumerated()
//        }
        
        if let totalCountList = reliabilityWindow?.totalClientCounts {
            totalClientCounts = intListToArray(totalCountList).enumerated()
        } else {
            totalClientCounts = [Int]().enumerated()
        }
        
        if let countryMultipliers = reliabilityWindow?.countryMultipliers {
            
            let n = countryMultipliers.len()
            print("countryMultipliers n is: \(n)")
            
            for i in 0..<n {
                
                guard let cm = countryMultipliers.get(i) else { continue }
                
                print("\(i): \(String(describing: cm.country)): \(String(describing: cm.reliabilityMultiplier))")
                
            }
            
            
        }
        
    }
    
    var body: some View {
        VStack(spacing: 0) {
            
            HStack {
                UrLabel(text: "Average reliability")
                Spacer()
            }
            
            HStack {
                Text(String(format: "%.2f%%", mean * 100))
                    .font(themeManager.currentTheme.titleCondensedFont)
                    .foregroundColor(themeManager.currentTheme.textColor)

                Spacer()
            }
            
            Chart {
                
                ForEach(Array(totalClientCounts), id: \.self.element) { index, counts in
                    LineMark(
                        x: .value("", index),
                        y: .value("Total Clients", counts),
                    )
                    .foregroundStyle(by: .value("key", "Total Clients"))
                }
                
//                ForEach(Array(clientCounts), id: \.self.element) { index, counts in
//                    LineMark(
//                        x: .value("", index),
//                        y: .value("Client Counts", counts),
//                    )
//                    .foregroundStyle(by: .value("key", "Active Clients"))
//                }
                
                ForEach(Array(reliabilityWeights), id: \.self.element) { index, weight in
                    
                    LineMark(
                        x: .value("", index),
                        y: .value("Reliability Weight", weight),
                    )
                    .foregroundStyle(by: .value("key", "Reliability Weight"))
                }
                
            }
            .chartXAxis(.hidden)
            .chartForegroundStyleScale([
                "Reliability Weight": .urPink.opacity(0.6),
                "Total Clients": .urGreen
            ])
            
        }
        .padding()
        .background(themeManager.currentTheme.tintedBackgroundBase)
        .cornerRadius(12)
    }
}

#Preview {
    NetworkReliabilityView(
        reliabilityWindow: SdkReliabilityWindow()
    )
}
