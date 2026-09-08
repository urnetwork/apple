//
//  ProPixellate.metal
//  URnetwork
//
//  The mosaic under the Pro celebration flight: every pixel takes the colour
//  of the centre of its `pixel`-sized cell, clamped to the layer's bounds so
//  the edges stay solid. Applied with SwiftUI's layerEffect
//  (ProCelebrationLayer.swift) on iOS 17 / macOS 14 and later.
//

#include <metal_stdlib>
#include <SwiftUI/SwiftUI.h>
using namespace metal;

[[ stitchable ]] half4 proPixellate(float2 position, SwiftUI::Layer layer, float pixel, float2 size) {
    float2 cell = floor(position / pixel) * pixel + pixel * 0.5;
    float2 clamped = clamp(cell, float2(0.0), size - 1.0);
    return layer.sample(clamped);
}
