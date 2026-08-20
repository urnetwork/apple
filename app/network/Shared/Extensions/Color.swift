//
//  Color.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2024/12/11.
//

import Foundation
import SwiftUI

// for SwiftUI Colors
extension Color {

    // a muted coral, used for the blocked packet series (maroon reads as
    // near-black against the dark background)
    static let urMutedCoral = Color(hex: "C8604F")

    // amber, used for runtime constraint warnings (a degraded Auto transport
    // policy); byte-matched to the other platforms' amber and distinct from
    // the whodis pump brand yellow
    static let urAmber = Color(hex: "F5C242")

    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }

        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue:  Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
