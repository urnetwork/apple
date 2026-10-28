//
//  TransportDelayLiveActivity.swift
//  URnetworkWidgets
//
//  The slow internet Live Activity (apple/DELAY.md §5.4): the tunnel in the
//  Dynamic Island and on the Lock Screen while the user's network delays
//  traffic, with the upload and download delays when expanded. This draws its
//  content. Off for now: nothing starts the activity, and the app declares no
//  NSSupportsLiveActivities. It returns with server pushes, the next step
//  (apple/DELAY.md §5.5), since ActivityKit lets only the running app drive
//  it (TransportDelayActivityAppDriver).
//
//  The system font, medium or heavier: this target bundles no fonts. The
//  tunnel fades by its squares on each update (TunnelIndicator), well inside
//  the 2 s animation cap; entry and exit are the system's.
//
//  iOS only: there is no Live Activity on the Mac.
//

#if os(iOS)
import ActivityKit
import SwiftUI
import WidgetKit

struct TransportDelayLiveActivity: Widget {

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TransportDelayAttributes.self) { context in
            TransportDelayLockScreenView(state: context.state, isStale: context.isStale)
                .activityBackgroundTint(TransportDelayActivityStyle.lockScreenBackground)
                .activitySystemActionForegroundColor(WidgetTheme.urWhite)
                .widgetURL(WidgetDestination.slowInternet.url)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    TransportDelayActivityHeader(state: context.state, tunnelSize: 36)
                        .dynamicIsland(verticalPlacement: .belowIfTooWide)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if !context.state.recovered {
                        TransportDelayActivityCards(
                            state: context.state,
                            isStale: context.isStale,
                            background: TransportDelayActivityStyle.islandCard,
                            cornerRadius: 17
                        )
                    }
                }
            } compactLeading: {
                // the island masks its leading content along its curve, which
                // cut the square corners of a tunnel at the region's edge
                TransportDelayActivityTunnel(state: context.state, size: 20)
                    .padding(.leading, 3)
            } compactTrailing: {
                Text(TransportDelayActivityCopy.slow)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(WidgetTheme.urAmber)
                    .opacity(context.state.recovered ? 0 : 1)
            } minimal: {
                // a square fits a circle only up to its diameter over √2: 17 pt
                // keeps the corners inside the 28 pt limited-width circle
                TransportDelayActivityTunnel(state: context.state, size: 17)
            }
            .keylineTint(WidgetTheme.urAmber)
            .widgetURL(WidgetDestination.slowInternet.url)
        }
    }
}

/// The copy, as resources with their fallback text: this target's sources
/// are not scanned by the app's catalog test, and iOS 27 traps in
/// LocalizedStringResource's string literal initializer in the widget
/// extension (QuickConnectControlMetadata). The keys are the app's catalog's.
enum TransportDelayActivityCopy {
    static var slowInternet: LocalizedStringResource {
        LocalizedStringResource("Slow internet", defaultValue: "Slow internet")
    }

    static var slow: LocalizedStringResource {
        LocalizedStringResource("Slow", defaultValue: "Slow")
    }

    static var fallbackTitle: LocalizedStringResource {
        LocalizedStringResource("Using a slower fallback connection", defaultValue: "Using a slower fallback connection")
    }

    static var stillConnected: LocalizedStringResource {
        LocalizedStringResource("URnetwork is still connected", defaultValue: "URnetwork is still connected")
    }

    static var uploadDelay: LocalizedStringResource {
        LocalizedStringResource("Upload delay", defaultValue: "Upload delay")
    }

    static var downloadDelay: LocalizedStringResource {
        LocalizedStringResource("Download delay", defaultValue: "Download delay")
    }

    static var recovered: LocalizedStringResource {
        LocalizedStringResource("Internet back to normal", defaultValue: "Internet back to normal")
    }

    static var recoveredDetail: LocalizedStringResource {
        LocalizedStringResource("Delays cleared", defaultValue: "Delays cleared")
    }
}

enum TransportDelayActivityStyle {
    static let lockScreenBackground = Color(white: 0.07).opacity(0.86)
    static let lockScreenCard = Color.white.opacity(0.06)
    static let islandCard = Color(white: 0.087)
    static let muted = Color(white: 0.63)

    static let title = Font.system(size: 17, weight: .semibold)
    static let subtitle = Font.system(size: 15, weight: .medium)
    static let caption = Font.system(size: 13, weight: .medium)
    static let number = Font.title3.weight(.semibold).monospacedDigit()
}

/// The tunnel at the content's level, fading from the level before it.
struct TransportDelayActivityTunnel: View {
    let state: TransportDelayAttributes.ContentState
    let size: CGFloat

    var body: some View {
        TunnelIndicator(
            depth: TunnelGeometry.depth(level: state.level),
            fromDepth: TunnelGeometry.depth(level: state.previousLevel),
            size: size
        )
        .accessibilityHidden(true)
    }
}

/// The tunnel, the title and the subtitle; the recovered state's one line.
struct TransportDelayActivityHeader: View {
    let state: TransportDelayAttributes.ContentState
    let tunnelSize: CGFloat

    var body: some View {
        HStack(spacing: 12) {
            TransportDelayActivityTunnel(state: state, size: tunnelSize)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(TransportDelayActivityStyle.title)
                    .foregroundColor(WidgetTheme.urWhite)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                Text(subtitle)
                    .font(TransportDelayActivityStyle.subtitle)
                    .foregroundColor(TransportDelayActivityStyle.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var title: LocalizedStringResource {
        if state.recovered {
            return TransportDelayActivityCopy.recovered
        }
        return state.fallback ? TransportDelayActivityCopy.fallbackTitle : TransportDelayActivityCopy.slowInternet
    }

    private var subtitle: LocalizedStringResource {
        state.recovered ? TransportDelayActivityCopy.recoveredDetail : TransportDelayActivityCopy.stillConnected
    }
}

/// The upload and download containers: the delay, and the rate when it was
/// limited. The worse direction's delay is amber; a stale activity's numbers
/// are muted. A direction with neither number has no container.
struct TransportDelayActivityCards: View {
    let state: TransportDelayAttributes.ContentState
    let isStale: Bool
    let background: Color
    let cornerRadius: CGFloat

    var body: some View {
        let worse = state.worseDirection
        HStack(alignment: .top, spacing: 10) {
            if hasNumbers(delayMillis: state.upDelayMillis, bitsPerSecond: state.upBitsPerSecond) {
                card(
                    title: TransportDelayActivityCopy.uploadDelay,
                    delayMillis: state.upDelayMillis,
                    bitsPerSecond: state.upBitsPerSecond,
                    worse: worse == .up
                )
            }
            if hasNumbers(delayMillis: state.downDelayMillis, bitsPerSecond: state.downBitsPerSecond) {
                card(
                    title: TransportDelayActivityCopy.downloadDelay,
                    delayMillis: state.downDelayMillis,
                    bitsPerSecond: state.downBitsPerSecond,
                    worse: worse == .down
                )
            }
        }
    }

    private func hasNumbers(delayMillis: Int64, bitsPerSecond: Int64) -> Bool {
        0 < delayMillis || 0 < bitsPerSecond
    }

    private func card(title: LocalizedStringResource, delayMillis: Int64, bitsPerSecond: Int64, worse: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(TransportDelayActivityStyle.caption)
                .foregroundColor(TransportDelayActivityStyle.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if let delay = TransportDelayFormat.delay(millis: delayMillis) {
                Text(verbatim: delay)
                    .font(TransportDelayActivityStyle.number)
                    .foregroundColor(numberColor(worse: worse))
                    .contentTransition(.numericText())
            }
            if let rate = TransportDelayFormat.rate(bitsPerSecond: bitsPerSecond) {
                Text(verbatim: rate)
                    .font(TransportDelayActivityStyle.caption.monospacedDigit())
                    .foregroundColor(TransportDelayActivityStyle.muted)
                    .contentTransition(.numericText())
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(background)
        )
        .accessibilityElement(children: .combine)
    }

    private func numberColor(worse: Bool) -> Color {
        if isStale {
            return TransportDelayActivityStyle.muted
        }
        return worse ? WidgetTheme.urAmber : WidgetTheme.urWhite
    }
}

/// The Lock Screen: the expanded content with 14 pt margins; the recovered
/// state is one line.
struct TransportDelayLockScreenView: View {
    let state: TransportDelayAttributes.ContentState
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TransportDelayActivityHeader(state: state, tunnelSize: 44)
            if !state.recovered {
                TransportDelayActivityCards(
                    state: state,
                    isStale: isStale,
                    background: TransportDelayActivityStyle.lockScreenCard,
                    cornerRadius: 14
                )
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#if DEBUG
extension TransportDelayAttributes.ContentState {
    /// The canvas's sample at each level.
    static func preview(level: Int, fallback: Bool = false) -> Self {
        let samples: [Int: (up: Int64, down: Int64, upRate: Int64, downRate: Int64)] = [
            1: (180, 260, 0, 0),
            2: (320, 480, 0, 410_000),
            3: (640, 1200, 48_000, 85_000),
            4: (1400, 2600, 21_000, 52_000),
        ]
        let sample = samples[level] ?? (0, 0, 0, 0)
        return Self(
            level: level,
            previousLevel: max(0, level - 1),
            upDelayMillis: sample.up,
            downDelayMillis: sample.down,
            upBitsPerSecond: sample.upRate,
            downBitsPerSecond: sample.downRate,
            fallback: fallback,
            recovered: false
        )
    }

    static var previewRecovered: Self {
        preview(level: 3).recoveredState
    }
}

#Preview("Compact", as: .dynamicIsland(.compact), using: TransportDelayAttributes()) {
    TransportDelayLiveActivity()
} contentStates: {
    TransportDelayAttributes.ContentState.preview(level: 1)
    TransportDelayAttributes.ContentState.preview(level: 2)
    TransportDelayAttributes.ContentState.preview(level: 3)
    TransportDelayAttributes.ContentState.preview(level: 4)
}

#Preview("Minimal", as: .dynamicIsland(.minimal), using: TransportDelayAttributes()) {
    TransportDelayLiveActivity()
} contentStates: {
    TransportDelayAttributes.ContentState.preview(level: 3)
}

#Preview("Expanded", as: .dynamicIsland(.expanded), using: TransportDelayAttributes()) {
    TransportDelayLiveActivity()
} contentStates: {
    TransportDelayAttributes.ContentState.preview(level: 3)
    TransportDelayAttributes.ContentState.preview(level: 4, fallback: true)
    TransportDelayAttributes.ContentState.previewRecovered
}

#Preview("Lock Screen", as: .content, using: TransportDelayAttributes()) {
    TransportDelayLiveActivity()
} contentStates: {
    TransportDelayAttributes.ContentState.preview(level: 3)
    TransportDelayAttributes.ContentState.preview(level: 1)
    TransportDelayAttributes.ContentState.previewRecovered
}
#endif
#endif
