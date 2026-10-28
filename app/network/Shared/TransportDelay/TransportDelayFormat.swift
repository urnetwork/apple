//
//  TransportDelayFormat.swift
//  URnetwork
//
//  The slow internet indicator's numbers (apple/DELAY.md §4). The units are
//  not localized, the same on every platform, and the numbers use a point
//  like the app's other rates (RateFormatUtils.swift). A 0 value has no text:
//  its line is hidden.
//
//  Compiled into the app and the widget extension.
//

import Foundation

enum TransportDelayFormat {

    /// A standing queue delay: "640 ms" under a second, "1.2 s" under ten,
    /// then whole seconds ("12 s"). nil for 0.
    static func delay(millis: Int64) -> String? {
        guard 0 < millis else {
            return nil
        }
        if millis < 1000 {
            return "\(millis) ms"
        }
        // tenths of a second, rounded half up; one that rounds to ten
        // seconds reads in whole seconds, like the values above it
        let tenths = (millis + 50) / 100
        if tenths < 100 {
            return "\(tenths / 10).\(tenths % 10) s"
        }
        let seconds = (millis + 500) / 1000
        return "\(seconds) s"
    }

    /// A network-limited rate in bits per second: whole kilobits under a
    /// megabit ("48 kb/s", at least 1), then megabits to one decimal
    /// ("1.4 Mb/s"). nil for 0.
    static func rate(bitsPerSecond: Int64) -> String? {
        guard 0 < bitsPerSecond else {
            return nil
        }
        let kilobits = max(1, (bitsPerSecond + 500) / 1000)
        if bitsPerSecond < 1_000_000 && kilobits < 1000 {
            return "\(kilobits) kb/s"
        }
        let tenths = (bitsPerSecond + 50_000) / 100_000
        return "\(tenths / 10).\(tenths % 10) Mb/s"
    }
}
