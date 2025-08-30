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
    let clientCounts: EnumeratedSequence<[Int]>
//    let totalClientCounts: EnumeratedSequence<[Int]>
    let mean: Double
    let countryMultipliers: [SdkCountryMultiplier]
    let reliabilityAverage: EnumeratedSequence<[Double]>
    
    
    init(reliabilityWindow: SdkReliabilityWindow?) {
        
        mean = reliabilityWindow?.meanReliabilityWeight ?? 0
        
        if let reliabilityWeightsList = reliabilityWindow?.reliabilityWeights {
            
            /**
             * Populate average weights array
             */
            var averageWeightsArr: [Double] = []
            
            for _ in 0..<reliabilityWeightsList.len() {
                averageWeightsArr.append(mean)
            }
            
            reliabilityAverage = averageWeightsArr.enumerated()
            
            reliabilityWeights = floatListToArray(reliabilityWeightsList).enumerated()
        } else {
            reliabilityAverage = [Double]().enumerated()
            reliabilityWeights = [Double]().enumerated()
        }
        
        
        if let clientCountsList = reliabilityWindow?.clientCounts {
            clientCounts = intListToArray(clientCountsList).enumerated()
        } else {
            clientCounts = [Int]().enumerated()
        }
        
//        if let totalCountList = reliabilityWindow?.totalClientCounts {
//            totalClientCounts = intListToArray(totalCountList).enumerated()
//        } else {
//            totalClientCounts = [Int]().enumerated()
//        }
        
        if let countryMultipliers = reliabilityWindow?.countryMultipliers {
            
            let n = countryMultipliers.len()
            var arr: [SdkCountryMultiplier] = []
            
            for i in 0..<n {
                
                guard let cm = countryMultipliers.get(i) else { continue }
                
                if (cm.reliabilityMultiplier > 1.0) {
                    arr.append(cm)
                }
                
            }
            
            self.countryMultipliers = arr
            
            
        } else {
            self.countryMultipliers = []
        }
        
        self.reliabilityWindow = reliabilityWindow
        
    }
    
    var body: some View {
        VStack(spacing: 0) {
            
            HStack {
                UrLabel(text: "Average reliability")
                Spacer()
            }
            
            HStack {
                Text(reliabilityWindow == nil ? "-" : String(format: "%.2f%", mean))
                    .font(themeManager.currentTheme.titleCondensedFont)
                    .foregroundColor(themeManager.currentTheme.textColor)

                Spacer()
            }
            
            Chart {
                
                ForEach(Array(reliabilityAverage), id: \.self.element) { index, avg in
                    LineMark(
                        x: .value("", index),
                        y: .value("Average Reliability", avg)
                    )
                    .foregroundStyle(by: .value("key", "Average Reliability"))
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 3])) // Dashed line
                }
                
                ForEach(Array(clientCounts), id: \.self.element) { index, counts in
                    LineMark(
                        x: .value("", index),
                        y: .value("Clients", counts),
                    )
                    .foregroundStyle(by: .value("key", "Clients"))
                }
                
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
                "Clients": .urGreen,
                "Average Reliability": themeManager.currentTheme.textMutedColor
            ])
            
            if countryMultipliers.count > 0 {
                
                Spacer().frame(height: 12)
             
                Divider()
                
                Spacer().frame(height: 12)
                
                CountryMultiplierList(countryMultipliers: countryMultipliers)
                
            }
            
        }
        .padding(.bottom)
    }
}

struct CountryMultiplierList: View {
    
    @EnvironmentObject var themeManager: ThemeManager
    
    var countryMultipliers: [SdkCountryMultiplier]
    
    let highlightThreshold = 2.0
    
    var body: some View {
        VStack() {
            
            HStack {
                Text("Country multipliers")
                    .font(themeManager.currentTheme.toolbarTitleFont)
                Spacer()
            }
            
            Spacer().frame(height: 12)
            
            HStack {
                UrLabel(text: "Country")
                Spacer()
                UrLabel(text: "Multiplier")
            }
            
            ForEach(countryMultipliers, id: \.countryLocationId) { countryMultiplier in
                
                Spacer().frame(height: 4)
                
                HStack {
                    Text(countryMultiplier.country)
                        .font(themeManager.currentTheme.bodyFont)
                        .foregroundColor(countryMultiplier.reliabilityMultiplier >= highlightThreshold ? .urGreen: .primary)
                    
                    Spacer()
                    
                    Text(String(format: "x%.2f%", countryMultiplier.reliabilityMultiplier))
                        .font(themeManager.currentTheme.bodyFont)
                        .foregroundColor(countryMultiplier.reliabilityMultiplier >= highlightThreshold ? .urGreen: .primary)
                }
                
            }
            
        }
    }
}

#Preview {
    NetworkReliabilityView(
        reliabilityWindow: SdkReliabilityWindow()
    )
}
