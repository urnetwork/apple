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
    var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .quality: return "Web"
        case .speed: return "Streaming"
        }
    }
}
