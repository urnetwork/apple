//
//  QuickConnectAndWidgetsView.swift
//  URnetwork
//
//  The quick connect control and the Home Screen widgets, with previews drawn
//  from sample data so they look like the real thing, and the steps to add
//  them, since iOS and macOS have no system request for adding a control or
//  pinning a widget. Shown on the last onboarding page and in Account >
//  Widgets, so the two never drift apart.
//

import SwiftUI

struct QuickConnectAndWidgetsView: View {

    @EnvironmentObject var themeManager: ThemeManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Turn URnetwork on and off from Control Center, and keep an eye on it from your Home Screen.")
                .font(themeManager.currentTheme.bodyFontLarge)

            Spacer().frame(height: 32)

            /**
             * The quick connect control: both states, then how to add it
             */
            HStack(spacing: 28) {
                QuickConnectControlPreview(connected: true)
                QuickConnectControlPreview(connected: false)
                Spacer()
            }

            Spacer().frame(height: 12)

            #if os(macOS)
            Text("Open Control Center, choose Edit Controls, and add URnetwork.")
                .font(themeManager.currentTheme.bodyFont)
                .foregroundColor(themeManager.currentTheme.textMutedColor)
            #else
            Text("Open Control Center, tap +, then Add a Control, and pick URnetwork.")
                .font(themeManager.currentTheme.bodyFont)
                .foregroundColor(themeManager.currentTheme.textMutedColor)
            #endif

            Spacer().frame(height: 32)

            /**
             * The widgets
             */
            Text("Add Home Screen widgets")
                .font(themeManager.currentTheme.toolbarTitleFont)

            Spacer().frame(height: 12)

            WidgetPreviewCard {
                DashboardWidgetPreview()
            }

            Spacer().frame(height: 10)

            HStack(alignment: .top, spacing: 10) {
                WidgetPreviewCard {
                    GlobeWidgetPreview()
                }
                WidgetPreviewCard {
                    ContractsWidgetPreview()
                }
            }

            Spacer().frame(height: 12)

            #if os(macOS)
            Text("Open the widget gallery from Notification Center, search URnetwork, and drag a widget to the desktop.")
                .font(themeManager.currentTheme.bodyFont)
                .foregroundColor(themeManager.currentTheme.textMutedColor)
            #else
            Text("Long-press the Home Screen, tap +, search URnetwork, and add a widget.")
                .font(themeManager.currentTheme.bodyFont)
                .foregroundColor(themeManager.currentTheme.textMutedColor)
            #endif
        }
    }
}

/**
 * A Control Center toggle as the system draws it: a rounded square with the
 * connector mark, filled with the app's tint when the tunnel is on.
 */
private struct QuickConnectControlPreview: View {

    let connected: Bool

    @EnvironmentObject var themeManager: ThemeManager

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 22)
                    .fill(connected ? Color.urPink : Color(red: 0.23, green: 0.23, blue: 0.24))
                Image("ur.symbols.connector.fill")
                    .font(.system(size: 30))
                    .foregroundColor(connected ? .urBlack : Color(red: 0.72, green: 0.72, blue: 0.72))
            }
            .frame(width: 72, height: 72)

            Group {
                if connected {
                    Text("Connected")
                } else {
                    Text("Disconnected")
                }
            }
            .font(themeManager.currentTheme.secondaryBodyFont)
            .foregroundColor(connected ? .urPink : themeManager.currentTheme.textMutedColor)
        }
    }
}

/// A widget-shaped card: the Home Screen's rounded tile on the widget's black.
private struct WidgetPreviewCard<Content: View>: View {

    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(red: 0.11, green: 0.11, blue: 0.11), in: RoundedRectangle(cornerRadius: 20))
    }
}

/// Sample traffic shaped like the real thing: a quiet floor with bursts that spike and decay.
private enum WidgetPreviewSample {

    static let buckets: [Double] = burstSeries(
        count: 60,
        bursts: [(7, 5.2, 0.62), (19, 2.4, 0.5), (31, 8.1, 0.7), (46, 3.6, 0.55), (55, 1.5, 0.45)],
        floor: 0.06,
        seed: 17
    )

    static let peakRate = "146 KiB/s"

    private static func burstSeries(count: Int, bursts: [(Int, Double, Double)], floor: Double, seed: UInt64) -> [Double] {
        var state = seed
        func noise() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double((state >> 33) % 1000) / 1000.0
        }
        var series = (0..<count).map { _ in floor * (0.6 + 0.8 * noise()) }
        for (at, peak, decay) in bursts {
            var level = peak
            var i = at
            while i < count && 0.02 * peak < level {
                series[i] += level * (0.85 + 0.3 * noise())
                level *= decay
                i += 1
            }
            if at > 0 { series[at - 1] += peak * 0.3 * noise() }
        }
        return series
    }
}

private struct DashboardWidgetPreview: View {

    @EnvironmentObject var themeManager: ThemeManager

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image("ur.symbols.connector.fill")
                .font(.system(size: 16))
                .foregroundColor(.urGreen)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: "Japan")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                Text(verbatim: "URnetwork")
                    .font(.system(size: 12))
                    .foregroundColor(themeManager.currentTheme.textMutedColor)
            }
            Spacer()
            // the quick connect button, pink like in the widget
            Image("ur.symbols.connector.fill")
                .font(.system(size: 22))
                .foregroundColor(.urPink)
        }

        Spacer().frame(height: 10)

        Text("Balance")
            .font(.system(size: 12))
            .foregroundColor(themeManager.currentTheme.textMutedColor)
        Spacer().frame(height: 4)
        GeometryReader { geometry in
            HStack(spacing: 0) {
                Capsule().fill(Color.urElectricBlue).frame(width: geometry.size.width * 0.33)
                Rectangle().fill(Color.urCoral).frame(width: geometry.size.width * 0.04)
                Rectangle().fill(themeManager.currentTheme.textFaintColor)
            }
            .clipShape(Capsule())
        }
        .frame(height: 10)

        Spacer().frame(height: 10)

        HStack {
            Text("Client")
                .font(.system(size: 12))
                .foregroundColor(themeManager.currentTheme.textMutedColor)
            Spacer()
            Text("\(WidgetPreviewSample.peakRate) peak")
                .font(.system(size: 12))
                .foregroundColor(themeManager.currentTheme.textMutedColor)
        }
        Spacer().frame(height: 4)
        ThroughputPreviewChart(values: WidgetPreviewSample.buckets, color: .urGreen)
            .frame(height: 52)
    }
}

/// The widget's mirrored traffic chart: download below the line, upload above, smoothed.
private struct ThroughputPreviewChart: View {

    let values: [Double]
    let color: Color

    var body: some View {
        Canvas { context, size in
            guard let peak = values.max(), peak > 0, values.count > 1 else { return }
            let centerY = size.height / 2
            let step = size.width / CGFloat(values.count - 1)
            func point(_ i: Int, up: Bool) -> CGPoint {
                let v = values[i] / peak
                let half = (size.height / 2 - 1)
                let y = up ? centerY - CGFloat(v * 0.18) * half : centerY + CGFloat(v) * half
                return CGPoint(x: CGFloat(i) * step, y: y)
            }
            var down = Path()
            var up = Path()
            down.move(to: CGPoint(x: 0, y: centerY))
            up.move(to: CGPoint(x: 0, y: centerY))
            for i in 0..<values.count {
                down.addLine(to: point(i, up: false))
                up.addLine(to: point(i, up: true))
            }
            down.addLine(to: CGPoint(x: size.width, y: centerY))
            up.addLine(to: CGPoint(x: size.width, y: centerY))
            context.fill(down, with: .color(color.opacity(0.25)))
            context.fill(up, with: .color(color.opacity(0.25)))
            context.stroke(down, with: .color(color), lineWidth: 1.5)
            context.stroke(up, with: .color(color), lineWidth: 1.5)
            context.stroke(
                Path { $0.move(to: CGPoint(x: 0, y: centerY)); $0.addLine(to: CGPoint(x: size.width, y: centerY)) },
                with: .color(Color.white.opacity(0.25)),
                lineWidth: 1
            )
        }
    }
}

private struct GlobeWidgetPreview: View {

    @EnvironmentObject var themeManager: ThemeManager

    var body: some View {
        HStack {
            Text("Providers")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
            Spacer()
            Text(verbatim: "3")
                .font(.system(size: 12))
                .foregroundColor(themeManager.currentTheme.textMutedColor)
        }
        Spacer().frame(height: 8)
        Canvas { context, size in
            let radius = min(size.width, size.height) / 2 - 2
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let globe = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius))
            context.fill(globe, with: .color(.white))
            context.clip(to: globe)
            // graticule
            for i in 1..<6 {
                let x = center.x - radius + 2 * radius * CGFloat(i) / 6
                let w = 2 * radius * abs(sin(.pi * CGFloat(i) / 6))
                let meridian = Path(ellipseIn: CGRect(x: center.x - w / 2, y: center.y - radius, width: w, height: 2 * radius))
                context.stroke(meridian, with: .color(Color.black.opacity(0.18)), lineWidth: 0.6)
                let parallel = Path { $0.move(to: CGPoint(x: center.x - radius, y: x)); $0.addLine(to: CGPoint(x: center.x + radius, y: x)) }
                context.stroke(parallel, with: .color(Color.black.opacity(0.18)), lineWidth: 0.6)
            }
            // a few land masses, loosely
            var land = Path()
            land.addEllipse(in: CGRect(x: center.x - radius * 0.55, y: center.y - radius * 0.7, width: radius * 0.6, height: radius * 0.75))
            land.addEllipse(in: CGRect(x: center.x + radius * 0.05, y: center.y - radius * 0.55, width: radius * 0.75, height: radius * 0.6))
            land.addEllipse(in: CGRect(x: center.x - radius * 0.15, y: center.y + radius * 0.05, width: radius * 0.45, height: radius * 0.7))
            context.fill(land, with: .color(.urBlack))
            // providers
            for (dx, dy, color) in [(0.1, -0.35, Color.urCoral), (-0.25, -0.1, Color.urElectricBlue), (0.35, 0.25, Color.urGreen)] {
                let p = CGRect(x: center.x + radius * dx - 3, y: center.y + radius * dy - 3, width: 6, height: 6)
                context.fill(Path(ellipseIn: p), with: .color(color))
            }
        }
        .frame(height: 110)
    }
}

private struct ContractsWidgetPreview: View {

    @EnvironmentObject var themeManager: ThemeManager

    private let peers: [(String, Int, Int)] = [("0199a2b4", 2, 1), ("44f1a2b4", 1, 2), ("9c3e5a7b", 1, 1)]

    var body: some View {
        Text("Contracts")
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(.white)
        Spacer().frame(height: 8)
        VStack(spacing: 6) {
            ForEach(peers, id: \.0) { peer in
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: peer.0)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.white)
                    HStack(spacing: 8) {
                        stack(count: peer.1, color: .urGreen, pointsRight: true)
                        stack(count: peer.2, color: .urPink, pointsRight: false)
                    }
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.urBlack, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func stack(count: Int, color: Color, pointsRight: Bool) -> some View {
        HStack(spacing: 3) {
            Image(systemName: pointsRight ? "arrow.right" : "arrow.left")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(color)
            ForEach(0..<count, id: \.self) { i in
                Circle()
                    .fill(color.opacity(i == 0 ? 0.45 : 0.25))
                    .overlay(Circle().stroke(color, lineWidth: i == 0 ? 1.5 : 0.8))
                    .frame(width: 14, height: 14)
            }
        }
    }
}

#Preview {
    ScrollView {
        QuickConnectAndWidgetsView()
            .padding()
    }
    .background(Color.urBlack)
    .environmentObject(ThemeManager.shared)
}
