//
//  DashboardSlowInternetPill.swift
//  URnetworkWidgets
//
//  The slow internet pill in the dashboard's header (apple/DELAY.md §5.7):
//  the connect screen's pill (SlowInternetPill) scaled to the widget's type,
//  in the provider count's place while the notice shows. Static: a widget
//  renders once per update, so the tunnel shows its level with no fades and
//  the digits do not roll.
//

import SwiftUI

/// A black rectangle with square corners in a 1 pt amber outline at 35%,
/// 22 pt tall: the 14 pt tunnel, the label in amber, then the upload and
/// download numbers in tabular digits, the worse one amber. With too little
/// room (a long location, a long translation) it drops the better direction,
/// then the numbers. The header around it is the accessibility element.
struct DashboardSlowInternetPill: View {
    let pill: SlowInternetWidgetPill

    var body: some View {
        HStack(spacing: 6) {
            TunnelIndicator(depth: TunnelGeometry.depth(level: pill.level), size: 14)
            ViewThatFits(in: .horizontal) {
                line(pill.content)
                line(pill.content.worseOnly)
                line(pill.content.labelOnly)
            }
            .lineLimit(1)
        }
        .padding(.leading, 5)
        .padding(.trailing, 8)
        .frame(height: 22)
        .background(Color.black)
        .overlay(Rectangle().strokeBorder(WidgetTheme.urAmber.opacity(0.35), lineWidth: 1))
    }

    /// The label, then the numbers that show.
    private func line(_ content: SlowInternetPillContent) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(Self.label(content.label))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(WidgetTheme.urAmber)
            if let up = content.up {
                number(arrow: "↑", up, worse: content.worse == .up)
            }
            if let down = content.down {
                number(arrow: "↓", down, worse: content.worse == .down)
            }
        }
    }

    /// One direction: its muted arrow, then its number.
    private func number(arrow: String, _ text: String, worse: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 1) {
            Text(verbatim: arrow)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(worse ? WidgetTheme.urAmber.opacity(0.75) : Color.white.opacity(0.55))
                .offset(y: -1)
            Text(verbatim: text)
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(worse ? WidgetTheme.urAmber : WidgetTheme.text)
        }
    }

    static func label(_ label: SlowInternetPillContent.Label) -> LocalizedStringResource {
        switch label {
        case .poorSignal:
            return SlowInternetWidgetCopy.poorSignal
        case .fallback:
            return SlowInternetWidgetCopy.fallback
        }
    }
}

/// The pill's copy, as resources with their fallback text, like the Live
/// Activity's (TransportDelayActivityCopy, which is iOS only): this target's
/// sources are not scanned by the app's catalog test. The keys are the app's
/// catalog's.
enum SlowInternetWidgetCopy {
    static var poorSignal: LocalizedStringResource {
        LocalizedStringResource("Poor signal", defaultValue: "Poor signal")
    }

    static var fallback: LocalizedStringResource {
        LocalizedStringResource("Fallback", defaultValue: "Fallback")
    }
}
