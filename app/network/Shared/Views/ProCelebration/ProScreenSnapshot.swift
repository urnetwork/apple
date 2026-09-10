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
//  iOS reads the key window back with drawHierarchy; macOS draws the key
//  window's content view into a bitmap with cacheDisplay. Both give the app
//  as it is on screen at the launch instant.
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
import AppKit

enum ProScreenSnapshot {
    /// The key window's content view, drawn with its descendants into a
    /// bitmap at the window's backing scale. AppKit has no "as it stands"
    /// screen read like UIKit's; `cacheDisplay` re-draws the view tree, which
    /// is the same content because the celebration overlay is still clear and
    /// the cell 0 at capture time.
    @MainActor
    static func capture() -> Image? {
        let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible })
        guard let contentView = window?.contentView else {
            return nil
        }
        let bounds = contentView.bounds
        guard 0 < bounds.width, 0 < bounds.height,
              let bitmap = contentView.bitmapImageRepForCachingDisplay(in: bounds) else {
            return nil
        }
        contentView.cacheDisplay(in: bounds, to: bitmap)
        let nsImage = NSImage(size: bounds.size)
        nsImage.addRepresentation(bitmap)
        return Image(nsImage: nsImage)
    }
}

#endif
