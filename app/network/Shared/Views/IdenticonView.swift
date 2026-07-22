//
//  IdenticonView.swift
//  URnetwork
//
//  Created by Brien Colwell on 7/21/26.
//

import SwiftUI
import URnetworkSdk

#if os(iOS)
typealias IdenticonImage = UIImage
#elseif os(macOS)
typealias IdenticonImage = NSImage
#endif

/**
 * The one component that renders an identity key identicon.
 *
 * The raster is the canonical square png from the SDK
 * (`SdkRenderIdenticonPng`), pre-resampled at 2x the point size for
 * crispness, so no view-side interpolation adjustment is wanted. The view
 * just sizes it and clips the corners with the standard slight rounding
 * (proportional to size, consistent everywhere identicons appear).
 *
 * Callers hold the platform image in their store/view model, cached per
 * (key, size) via `renderImage` -- never render per body evaluation.
 */
struct IdenticonView: View {

    let image: IdenticonImage?
    let size: CGFloat

    var body: some View {
        Group {
            if let image = image {
                #if os(iOS)
                Image(uiImage: image)
                    .resizable()
                #elseif os(macOS)
                Image(nsImage: image)
                    .resizable()
                #endif
            } else {
                // key not available yet: a quiet placeholder with the same
                // footprint, so the layout does not jump when the key loads
                Color.secondary.opacity(0.15)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size / 6))
    }

    /**
     * Render the canonical identicon for `key` at 2x the display point size.
     */
    static func renderImage(key: Data, size: CGFloat) -> IdenticonImage? {
        guard let png = SdkRenderIdenticonPng(key, Int(size * 2), nil) else {
            return nil
        }
        return IdenticonImage(data: png)
    }
}
