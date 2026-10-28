//
//  TransportDelayAttributes.swift
//  URnetwork
//
//  The slow internet indicator's data, shared by every process that shows it
//  (apple/DELAY.md §5): the device's transport delay reading as a plain value,
//  its level, and the Live Activity's attributes and content.
//
//  Compiled into the app, the packet tunnel extension and the widget
//  extension (listed explicitly in their sources phases, like
//  WidgetSnapshots.swift). No SDK import and no SwiftUI, on purpose: the app
//  binds URnetworkSdk, the extension URnetworkExtensionSdk, the widgets
//  neither, and the extension keeps SwiftUI out of its memory budget.
//

import Foundation
#if os(iOS)
import ActivityKit
#endif

/// The level of a quantized transport quality: 0 (normal) to 4 (worst), one
/// step per TransportDelayQualityStep (0.25). The indicator follows the worse
/// direction (apple/DELAY.md §1).
enum TransportDelayLevel {
    static let maximum = 4

    /// 0 for a quality of 0, else at least 1: any non-zero quality shows.
    static func level(quality: Double) -> Int {
        guard quality.isFinite, 0 < quality else {
            return 0
        }
        let level = Int((quality * Double(maximum)).rounded())
        return min(maximum, max(1, level))
    }

    /// The quality a level stands for, 0 to 1.
    static func quality(level: Int) -> Double {
        Double(min(maximum, max(0, level))) / Double(maximum)
    }
}

/// One reading of the device's transport delay (sdk `TransportDelay`), mapped
/// off the sdk object so every process, the dwell policy and the tests share
/// one plain value.
struct TransportDelayReading: Codable, Equatable {
    /// 0 (normal) to 1 (worst), quantized by the sdk
    var upQuality: Double = 0
    var downQuality: Double = 0
    /// the worst network-limited throughput in the window. 0: not limited
    var upBitsPerSecond: Int64 = 0
    var downBitsPerSecond: Int64 = 0
    /// the worst standing queue in the window. 0: none
    var upDelayMillis: Int64 = 0
    var downDelayMillis: Int64 = 0
    /// the worst reading came from a slower DNS-carried fallback transport
    var fallback: Bool = false

    static let normal = TransportDelayReading()

    /// The worse direction's level, 0 to 4.
    var level: Int {
        TransportDelayLevel.level(quality: max(upQuality, downQuality))
    }
}

/// Which direction's delay is the worse one: its number is drawn amber. The
/// larger delay is the worse; equal delays mark neither.
enum TransportDelayDirection: Equatable {
    case up
    case down

    static func worse(upDelayMillis: Int64, downDelayMillis: Int64) -> TransportDelayDirection? {
        if downDelayMillis < upDelayMillis {
            return .up
        }
        if upDelayMillis < downDelayMillis {
            return .down
        }
        return nil
    }
}

/// The slow internet Live Activity (apple/DELAY.md §5.4). The attributes
/// carry nothing: one activity per device, everything it shows is content.
struct TransportDelayAttributes: Codable, Hashable {

    struct ContentState: Codable, Hashable {
        /// 0 to 4. 0 only in the recovered state, just before the end
        var level: Int
        /// the level before this update, so each square of the tunnel fades
        /// in its order from the first one that changes (§3): a widget view
        /// keeps no state between updates
        var previousLevel: Int
        var upDelayMillis: Int64
        var downDelayMillis: Int64
        /// 0: not limited, the line is hidden
        var upBitsPerSecond: Int64
        var downBitsPerSecond: Int64
        /// the title is "Using a slower fallback connection"
        var fallback: Bool
        /// "Internet back to normal": shown for a few seconds before the end
        var recovered: Bool

        /// The content showing `reading`, after `previousLevel`.
        init(reading: TransportDelayReading, previousLevel: Int) {
            self.level = reading.level
            self.previousLevel = previousLevel
            self.upDelayMillis = reading.upDelayMillis
            self.downDelayMillis = reading.downDelayMillis
            self.upBitsPerSecond = reading.upBitsPerSecond
            self.downBitsPerSecond = reading.downBitsPerSecond
            self.fallback = reading.fallback
            self.recovered = false
        }

        init(
            level: Int,
            previousLevel: Int,
            upDelayMillis: Int64,
            downDelayMillis: Int64,
            upBitsPerSecond: Int64,
            downBitsPerSecond: Int64,
            fallback: Bool,
            recovered: Bool
        ) {
            self.level = level
            self.previousLevel = previousLevel
            self.upDelayMillis = upDelayMillis
            self.downDelayMillis = downDelayMillis
            self.upBitsPerSecond = upBitsPerSecond
            self.downBitsPerSecond = downBitsPerSecond
            self.fallback = fallback
            self.recovered = recovered
        }

        /// The recovered state that follows this content: the tunnel fades to
        /// nothing and the numbers go.
        var recoveredState: ContentState {
            ContentState(
                level: 0,
                previousLevel: level,
                upDelayMillis: 0,
                downDelayMillis: 0,
                upBitsPerSecond: 0,
                downBitsPerSecond: 0,
                fallback: fallback,
                recovered: true
            )
        }

        /// The same content as an update with no change of level: the tunnel
        /// stays as it is while only the numbers move.
        var settled: ContentState {
            var settled = self
            settled.previousLevel = level
            return settled
        }

        var worseDirection: TransportDelayDirection? {
            TransportDelayDirection.worse(upDelayMillis: upDelayMillis, downDelayMillis: downDelayMillis)
        }
    }
}

#if os(iOS)
@available(iOS 16.1, *)
extension TransportDelayAttributes: ActivityAttributes {}
#endif
