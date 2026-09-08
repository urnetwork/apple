//
//  ProSpriteFlight.swift
//  URnetwork
//
//  The Pro celebration: a 15 s confetti stream of pixel sunglasses, eye
//  covers and face discs racing from off the left edge to off the right
//  edge, every one on its own lane, at its own speed, size and bob,
//  pitching with its vertical velocity and towing a light trail. Some fly
//  behind (smaller, dimmer), some in front. Everything is drawn in one
//  Canvas from three pixel paths, so a flight costs one draw pass per
//  frame. The overlay takes no touches and is decoration only.
//
//  The sprites are the Android flight's, in the 12-unit pixel grid of the
//  privacy glasses: the sunglasses in the pink accent with black lens
//  highlights, a black stair-stepped eye cover with two pink glints, and a
//  Pro-gold stepped disc with two black glints.
//

import SwiftUI

/// A steady stream: a new sprite about every 150 ms (with a little jitter) until the last one
/// can still leave the screen before the confetti ends.
private let spawnIntervalSeconds = 0.15
private let spawnJitterSeconds = 0.03
/// Time to cross the screen, fast to slow.
private let minCrossingSeconds = 1.2
private let maxCrossingSeconds = 1.9
/// The most sprites in the air at once; the schedule skips a take-off that would exceed it.
private let maxLiveSprites = 30
private let pitchDegrees = 20.0
private let trailCount = 2
private let trailStep: CGFloat = 18

private enum SpriteKind: CaseIterable {
    case sunglasses
    case eyeCover
    case faceCover
}

/// One sprite of the burst, fixed for the whole flight.
private struct Sprite {
    let kind: SpriteKind
    let delaySeconds: Double
    let crossingSeconds: Double
    /// Vertical lane, as a fraction of the height.
    let lane: Double
    let bobAmplitude: CGFloat
    let bobCycles: Double
    let phaseOffset: Double
    let scale: CGFloat
    let behind: Bool
}

/// A small deterministic generator (SplitMix64), so a sequence replays the same burst on
/// every host and nothing touches the process-wide random state.
private struct SeededRandom {
    private var state: UInt64

    init(seed: Int) {
        state = UInt64(bitPattern: Int64(seed)) &+ 0x9E37_79B9_7F4A_7C15
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A uniform value in [0, 1).
    mutating func nextUnit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }

    mutating func nextInt(_ bound: Int) -> Int {
        Int(nextUnit() * Double(bound))
    }
}

/// The whole take-off schedule of one flight, computed once at launch: sprites take off at a
/// steady rate for the first part of the confetti window so the last one has left the screen
/// by `confettiSeconds`, and nothing spawns after that. Behind first, so the front layer draws
/// over it.
private func burst(seed: Int) -> [Sprite] {
    var random = SeededRandom(seed: seed)
    var sprites: [Sprite] = []
    var takeOff = 0.0
    let lastTakeOff = ProCelebrationTiming.confettiSeconds - maxCrossingSeconds
    while takeOff <= lastTakeOff {
        let crossing = minCrossingSeconds + random.nextUnit() * (maxCrossingSeconds - minCrossingSeconds)
        let scale = 0.6 + random.nextUnit() * 0.6
        let live = sprites.filter { $0.delaySeconds + $0.crossingSeconds > takeOff }.count
        let kind: SpriteKind
        switch random.nextInt(5) {
        case 0, 1: kind = .sunglasses
        case 2, 3: kind = .eyeCover
        default: kind = .faceCover
        }
        let bobAmplitude = CGFloat(12 + random.nextInt(29))
        let bobCycles = 2 + random.nextUnit() * 2
        let phaseOffset = random.nextUnit() * 2 * .pi
        let lane = 0.08 + random.nextUnit() * 0.84
        if live < maxLiveSprites {
            sprites.append(Sprite(
                kind: kind,
                delaySeconds: takeOff,
                crossingSeconds: crossing,
                lane: lane,
                bobAmplitude: bobAmplitude,
                bobCycles: bobCycles,
                phaseOffset: phaseOffset,
                scale: CGFloat(scale),
                // the small ones fly behind
                behind: scale < 0.85
            ))
        }
        takeOff += spawnIntervalSeconds + (random.nextUnit() * 2 - 1) * spawnJitterSeconds
    }
    return sprites.sorted { $0.behind && !$1.behind }
}

/// A pixel sprite: filled paths in unit space (the 12-unit grid) with their colours, and the
/// size it is drawn at on screen at scale 1.
private struct PixelSprite {
    let unitSize: CGSize
    let drawSize: CGSize
    let layers: [(path: Path, color: Color)]

    func draw(in context: inout GraphicsContext) {
        let sx = drawSize.width / unitSize.width
        let sy = drawSize.height / unitSize.height
        context.scaleBy(x: sx, y: sy)
        for layer in layers {
            context.fill(layer.path, with: .color(layer.color))
        }
    }
}

private let spritePink = Color(red: 0xED / 255.0, green: 0x8F / 255.0, blue: 1.0)
private let spriteInk = Color(red: 0x10 / 255.0, green: 0x10 / 255.0, blue: 0x10 / 255.0)
private let spriteGold = Color(red: 1.0, green: 0xC4 / 255.0, blue: 0.0)

/// Parses the flat pixel path data the sprites are drawn with: absolute M/H/V, relative h/v,
/// and Z. Nothing else appears in these shapes.
private func pixelPath(_ data: String) -> Path {
    var path = Path()
    var point = CGPoint.zero
    var start = CGPoint.zero
    var index = data.startIndex

    func number() -> CGFloat {
        var text = ""
        while index < data.endIndex {
            let c = data[index]
            if c.isNumber || c == "-" || c == "." {
                text.append(c)
                index = data.index(after: index)
            } else if c == "," {
                index = data.index(after: index)
                if !text.isEmpty { break }
            } else {
                break
            }
        }
        return CGFloat(Double(text) ?? 0)
    }

    while index < data.endIndex {
        let command = data[index]
        index = data.index(after: index)
        switch command {
        case "M":
            let x = number()
            let y = number()
            point = CGPoint(x: x, y: y)
            start = point
            path.move(to: point)
        case "H":
            point.x = number()
            path.addLine(to: point)
        case "V":
            point.y = number()
            path.addLine(to: point)
        case "h":
            point.x += number()
            path.addLine(to: point)
        case "v":
            point.y += number()
            path.addLine(to: point)
        case "Z", "z":
            path.closeSubpath()
            point = start
        default:
            break
        }
    }
    return path
}

private func squares(_ cells: [(CGFloat, CGFloat)]) -> Path {
    var path = Path()
    for (x, y) in cells {
        path.addRect(CGRect(x: x, y: y, width: 12, height: 12))
    }
    return path
}

/// The pixel sunglasses (the privacy glasses geometry) in the pink accent with black lens
/// highlights.
private let sunglassesSprite = PixelSprite(
    unitSize: CGSize(width: 264, height: 60),
    drawSize: CGSize(width: 96, height: 22),
    layers: [
        (pixelPath("M0,0V24H12V36H24V48H36V60H96V48H108V36H120V24H144V36H156V48H168V60H228V48H240V36H252V24H264V0H0Z"), spritePink),
        (squares([(24, 12), (48, 12), (36, 24), (60, 24), (48, 36), (72, 36),
                  (156, 12), (180, 12), (168, 24), (192, 24), (180, 36), (204, 36)]), spriteInk),
    ]
)

/// A square eye cover: the pixel censor bar with the same stair-stepped corners.
private let eyeCoverSprite = PixelSprite(
    unitSize: CGSize(width: 264, height: 96),
    drawSize: CGSize(width: 96, height: 35),
    layers: [
        (pixelPath("M24,0H240V12H252V24H264V72H252V84H240V96H24V84H12V72H0V24H12V12H24Z"), spriteInk),
        (squares([(36, 12), (216, 72)]), spritePink),
    ]
)

/// A circular face cover: a stepped pixel disc in the Pro gold accent.
private let faceCoverSprite = PixelSprite(
    unitSize: CGSize(width: 144, height: 144),
    drawSize: CGSize(width: 64, height: 64),
    layers: [
        (pixelPath("M48,0H96V12H120V24H132V48H144V96H132V120H120V132H96V144H48V132H24V120H12V96H0V48H12V24H24V12H48Z"), spriteGold),
        (squares([(36, 24), (24, 36)]), spriteInk),
    ]
)

private func sprite(for kind: SpriteKind) -> PixelSprite {
    switch kind {
    case .sunglasses: return sunglassesSprite
    case .eyeCover: return eyeCoverSprite
    case .faceCover: return faceCoverSprite
    }
}

/// Draws the confetti of one flight for the given moment. `seconds` counts from the launch;
/// nothing is drawn once the confetti window has passed.
struct ProSpriteFlight: View {

    /// The flight's sequence: seeds the burst, so a replay is a new mix.
    let sequence: Int
    /// Seconds since the flight was launched.
    let seconds: Double

    var body: some View {
        let sprites = burst(seed: sequence)
        Canvas(rendersAsynchronously: true) { context, size in
            guard seconds >= 0, seconds < ProCelebrationTiming.confettiSeconds else {
                return
            }
            for item in sprites {
                let local = (seconds - item.delaySeconds) / item.crossingSeconds
                if local <= 0 || local >= 1 {
                    continue
                }
                let t = ProCelebrationTiming.easeInOut(local)
                let art = sprite(for: item.kind)
                let spriteWidth = art.drawSize.width * item.scale
                let travel = size.width + 2 * spriteWidth
                let laneY = size.height * item.lane
                let layerAlpha = item.behind ? 0.55 : 1.0

                // the trail: fading copies a step behind
                for i in stride(from: trailCount, through: 1, by: -1) {
                    let trailT = max(t - Double(CGFloat(i) * trailStep / travel), 0)
                    drawSprite(
                        &context,
                        art: art,
                        x: -spriteWidth + CGFloat(trailT) * travel - CGFloat(i) * trailStep,
                        laneY: laneY,
                        item: item,
                        progress: trailT,
                        alpha: layerAlpha * (0.28 - 0.1 * Double(i)),
                        scale: item.scale * (1 - 0.08 * CGFloat(i))
                    )
                }
                drawSprite(
                    &context,
                    art: art,
                    x: -spriteWidth + CGFloat(t) * travel,
                    laneY: laneY,
                    item: item,
                    progress: t,
                    alpha: layerAlpha,
                    scale: item.scale
                )
            }
        }
        // decoration only: never announced, never a touch target
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func drawSprite(
        _ context: inout GraphicsContext,
        art: PixelSprite,
        x: CGFloat,
        laneY: CGFloat,
        item: Sprite,
        progress: Double,
        alpha: Double,
        scale: CGFloat
    ) {
        let phase = 2 * Double.pi * item.bobCycles * progress + item.phaseOffset
        // the vertical velocity sets the pitch: nose up while rising (y decreasing on
        // screen), nose down while falling
        let y = laneY + item.bobAmplitude * CGFloat(sin(phase)) - art.drawSize.height * scale / 2
        let pitch = -pitchDegrees * cos(phase)
        var layer = context
        layer.opacity = alpha
        layer.translateBy(x: x, y: y)
        layer.scaleBy(x: scale, y: scale)
        // pitch about the sprite's center
        layer.translateBy(x: art.drawSize.width / 2, y: art.drawSize.height / 2)
        layer.rotate(by: .degrees(pitch))
        layer.translateBy(x: -art.drawSize.width / 2, y: -art.drawSize.height / 2)
        art.draw(in: &layer)
    }
}
