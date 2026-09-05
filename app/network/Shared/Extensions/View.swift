//
//  View.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2025/01/07.
//

import Foundation
import SwiftUI

extension View {
    // Keep the system presentation background on the supported older OSes.
    @ViewBuilder
    func presentationBackgroundIfAvailable<S: ShapeStyle>(_ style: S) -> some View {
        if #available(iOS 16.4, macOS 13.3, tvOS 16.4, watchOS 9.4, *) {
            presentationBackground(style)
        } else {
            self
        }
    }
}

#if canImport(UIKit)
import UIKit

extension View {
    func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}
#endif
