//
//  ProScreenSnapshot.swift
//  URnetwork
//
//  A one-shot raster of the current screen for the Pro celebration mosaic.
//
//  The pixelation is a layer effect and it samples an offscreen raster of its
//  content. The live app content is UIKit-backed (the tab view, a
//  NavigationStack) and cannot be rendered into that raster -- SwiftUI
//  substitutes the unsupported-view placeholder for the whole region -- which
//  is why the celebration layer sits over a clear overlay and, before this,
//  pixelated nothing. A snapshot Image is plain SwiftUI, so it can be sampled:
//  freeze the screen the instant a flight launches and pixelate the frozen
//  copy while the live UI carries on underneath.
//

import SwiftUI

#if os(iOS)
import UIKit

enum ProScreenSnapshot {
    /// The key window's current on-screen content, or nil when there is no
    /// window or it has no size. Captured with `afterScreenUpdates: false` so
    /// it is the screen as it stands now, not a re-render that would fold in
    /// the celebration's own overlay mid-change.
    @MainActor
    static func capture() -> Image? {
        let windowScenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = windowScenes.flatMap { $0.windows }
        guard let window = windows.first(where: { $0.isKeyWindow }) ?? windows.first else {
            return nil
        }
        let bounds = window.bounds
        guard 0 < bounds.width, 0 < bounds.height else {
            return nil
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = window.screen.scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(bounds: bounds, format: format)
        let uiImage = renderer.image { _ in
            window.drawHierarchy(in: bounds, afterScreenUpdates: false)
        }
        return Image(uiImage: uiImage)
    }
}

#else

enum ProScreenSnapshot {
    /// No AppKit snapshot: macOS keeps the confetti-only celebration it had
    /// before the snapshot mosaic, rather than risk the placeholder on a
    /// window kind this was not measured against.
    @MainActor
    static func capture() -> Image? {
        nil
    }
}

#endif
