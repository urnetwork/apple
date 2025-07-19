//
//  ProvideControlMode.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 7/18/25.
//

import Foundation

enum ProvideControlMode: String, CaseIterable, Identifiable {
    case Auto = "auto"
    case Always = "always"
    case Never = "never"
    
    var id: Self { self }
}
