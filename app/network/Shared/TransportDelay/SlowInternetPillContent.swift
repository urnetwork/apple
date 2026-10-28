//
//  SlowInternetPillContent.swift
//  URnetwork
//
//  What the slow internet pill says (apple/DELAY.md §5.2), shared by the
//  connect screen's pill (SlowInternetIndicator.swift, which adds its motion
//  and its recovered state) and the dashboard widget's (§5.7), which shows
//  the notice's content on the notice's dwell. The rules are values, pinned
//  by SlowInternetPillContentTests and SlowInternetWidgetPillTests.
//
//  Compiled into the app and the widget extension. No SDK import.
//

import SwiftUI

/// What the pill says (apple/DELAY.md §5.2), as a value so its rules are
/// tested (SlowInternetPillContentTests). "Poor signal", or "Fallback" on the
/// fallback connection; then each direction's standing delay, or its limited
/// rate when it has no delay, and nothing when it has neither. The larger
/// delay is the worse direction, drawn amber. Recovered, the pill says
/// "Internet back to normal" instead.
struct SlowInternetPillContent: Equatable {

    enum Label: Equatable {
        case poorSignal
        case fallback
    }

    var label: Label
    /// "640 ms", or "48 kb/s" with no delay; nil hides the direction.
    var up: String?
    var down: String?
    /// The larger delay's direction; nil when the delays are equal.
    var worse: TransportDelayDirection?
    /// The few seconds after a return to normal, before the pill leaves.
    var recovered = false

    /// What the pill says for a slow reading.
    init(reading: TransportDelayReading) {
        label = reading.fallback ? .fallback : .poorSignal
        // the standing delay, else the limited rate, else nothing
        up = TransportDelayFormat.delay(millis: reading.upDelayMillis)
            ?? TransportDelayFormat.rate(bitsPerSecond: reading.upBitsPerSecond)
        down = TransportDelayFormat.delay(millis: reading.downDelayMillis)
            ?? TransportDelayFormat.rate(bitsPerSecond: reading.downBitsPerSecond)
        worse = TransportDelayDirection.worse(upDelayMillis: reading.upDelayMillis, downDelayMillis: reading.downDelayMillis)
    }

    /// What the pill says for the notice's content, the dashboard widget's:
    /// the same rules on the numbers the dwell policy last published, which
    /// are all the copy reads of a reading.
    init(activity: TransportDelayAttributes.ContentState) {
        self.init(reading: TransportDelayReading(
            upBitsPerSecond: activity.upBitsPerSecond,
            downBitsPerSecond: activity.downBitsPerSecond,
            upDelayMillis: activity.upDelayMillis,
            downDelayMillis: activity.downDelayMillis,
            fallback: activity.fallback
        ))
    }

    /// With room for one direction: the worse one, or the download when
    /// neither is worse (the upload when only it shows).
    var worseOnly: SlowInternetPillContent {
        var content = self
        switch worse ?? (down != nil ? .down : .up) {
        case .up:
            content.down = nil
        case .down:
            content.up = nil
        }
        return content
    }

    /// With no room for numbers: the tunnel and the label.
    var labelOnly: SlowInternetPillContent {
        var content = self
        content.up = nil
        content.down = nil
        return content
    }
}

/// The dashboard widget's pill (apple/DELAY.md §5.7): the notice's level and
/// what the in-app pill says for its numbers. A surface outside the app, so
/// it follows the notice's dwell rather than the sdk's level, and has no
/// recovered state: a widget cannot hold one for 3 s.
struct SlowInternetWidgetPill: Equatable {
    /// 1 to 4: the tunnel shows its depth, with no motion.
    var level: Int
    var content: SlowInternetPillContent

    /// What the dashboard shows of the extension's last snapshot, read at
    /// `now`: the pill while the notice shows (`dashboardActivity`), and
    /// nothing with no snapshot (the Mac's extension writes none), from an
    /// extension that stopped writing (`isFresh`), or while the widget shows
    /// no tunnel data (signed out or disconnected).
    static func decide(snapshot: TransportDelaySnapshot?, showsTunnelData: Bool, now: Date) -> SlowInternetWidgetPill? {
        guard showsTunnelData,
              let snapshot,
              snapshot.isFresh(now: now),
              let activity = snapshot.dashboardActivity else {
            return nil
        }
        return SlowInternetWidgetPill(level: activity.level, content: SlowInternetPillContent(activity: activity))
    }
}

/// The accessibility text for the numbers.
enum SlowInternetText {

    /// "Upload delay 640 ms, Download delay 1.2 s": each direction's text in
    /// the pill (its delay, or its limited rate), leaving out a direction
    /// with neither.
    static func delaysValue(up: String?, down: String?) -> Text {
        switch (up, down) {
        case let (up?, down?):
            return Text("Upload delay") + Text(verbatim: " \(up), ") + Text("Download delay") + Text(verbatim: " \(down)")
        case let (up?, nil):
            return Text("Upload delay") + Text(verbatim: " \(up)")
        case let (nil, down?):
            return Text("Download delay") + Text(verbatim: " \(down)")
        case (nil, nil):
            return Text(verbatim: "")
        }
    }
}
