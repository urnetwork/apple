//
//  WindowType.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 1/8/26.
//

import Foundation

enum WindowType: String, CaseIterable, Identifiable {
    case auto = "auto"
    case quality = "quality"
    case speed = "speed"
    
    var id: String { self.rawValue }
    // localized via the string catalog (window_type_* store keys)
    var displayName: String {
        switch self {
        case .auto: return String(localized: "Auto")
        case .quality: return String(localized: "Web")
        case .speed: return String(localized: "Streaming")
        }
    }
}
