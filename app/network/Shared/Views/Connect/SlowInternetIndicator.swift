//
//  SlowInternetIndicator.swift
//  URnetwork
//
//  The slow internet pill on the connect screen (top right on iOS, a toolbar
//  item on the Mac), the notify toggle in Settings, and the macOS menu bar
//  row (apple/DELAY.md §1, §5.2, §5.3, §6). The pill is a readout, not a
//  button: it shows the delays itself, so nothing opens from it. It follows
//  the sdk's level directly; only the notification dwells.
//

import SwiftUI

/// The tunnel in the app: tracks the depth it last drew, so each change fades
/// the squares that change in their order (TunnelMotion), and builds in from
/// nothing when it appears.
struct AnimatedTunnelIndicator: View {
    let depth: Int
    let size: CGFloat
    var color: Color = .urAmber

    @State private var shownDepth = 0
    @State private var fromDepth = 0

    var body: some View {
        TunnelIndicator(depth: shownDepth, fromDepth: fromDepth, size: size, color: color)
            .onAppear {
                fromDepth = 0
                shownDepth = depth
            }
            .onChange(of: depth) { next in
                fromDepth = shownDepth
                shownDepth = next
            }
    }
}

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

    /// What the pill shows once `state` arrives, after `shown` (nil when the
    /// pill is not up, or is leaving):
    /// - while the level is above 0, the slow content, which also takes the
    ///   recovered state's place;
    /// - on a return to normal from the slow content, the recovered state,
    ///   which then holds;
    /// - nil, the pill leaving, when the reading goes away (unavailable: a
    ///   reset, or the device remote unlinked) or something more severe has
    ///   the top of the screen (`hidden`). Neither is a recovery.
    static func next(after shown: SlowInternetPillContent?, state: TransportDelayState, hidden: Bool) -> SlowInternetPillContent? {
        guard !hidden else {
            return nil
        }
        if 0 < state.level {
            return SlowInternetPillContent(reading: state.reading)
        }
        guard state.available, let shown else {
            return nil
        }
        if shown.recovered {
            return shown
        }
        var recovered = shown.labelOnly
        recovered.worse = nil
        recovered.recovered = true
        return recovered
    }
}

/// The pill (apple/DELAY.md §5.2): a black rectangle with square corners,
/// like the tunnel's, in the 35% amber outline the island draws around a
/// Live Activity. The 18 pt tunnel, the label in amber, then the upload and
/// download numbers in tabular digits, the worse one amber. With too little
/// room (large text, a long translation) it drops the better direction, then
/// the numbers. Recovered, a green check takes the tunnel's place and
/// "Internet back to normal" the copy's. One accessibility element: the
/// label, with the numbers as its value.
struct SlowInternetPill: View {
    @EnvironmentObject var themeManager: ThemeManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The tunnel's level: 0 while it fades out.
    let level: Int
    let content: SlowInternetPillContent

    // the design's 14, 13 and 10 pt, scaled with Dynamic Type
    @ScaledMetric(relativeTo: .subheadline) private var labelSize: CGFloat = 14
    @ScaledMetric(relativeTo: .footnote) private var numberSize: CGFloat = 13
    @ScaledMetric(relativeTo: .caption2) private var arrowSize: CGFloat = 10

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                AnimatedTunnelIndicator(depth: TunnelGeometry.depth(level: level), size: 18)
                // square, like the tunnel
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundColor(.urBlack)
                    .frame(width: 16, height: 16)
                    .background(Color.urGreen)
                    .opacity(content.recovered ? 1 : 0)
            }
            .frame(width: 18, height: 18)
            ZStack(alignment: .leading) {
                if content.recovered {
                    Text("Internet back to normal")
                        .font(.system(size: numberSize, weight: .semibold))
                        .foregroundColor(themeManager.currentTheme.textColor)
                        .transition(.opacity)
                } else {
                    ViewThatFits(in: .horizontal) {
                        line(content)
                        line(content.worseOnly)
                        line(content.labelOnly)
                    }
                    .transition(.opacity)
                }
            }
            .lineLimit(1)
        }
        .padding(.leading, 6)
        .padding(.trailing, 10)
        .padding(.vertical, 4)
        .frame(minHeight: 30)
        .background(Color.black)
        .overlay(Rectangle().strokeBorder(Color.urAmber.opacity(0.35), lineWidth: 1))
        // the copy fading out as the width eases stays inside
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(content.recovered ? Text("Internet back to normal") : Self.label(content.label))
        .accessibilityValue(SlowInternetText.delaysValue(up: content.up, down: content.down))
    }

    /// The slow copy: the label, then the numbers that show.
    private func line(_ content: SlowInternetPillContent) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Self.label(content.label)
                .font(.system(size: labelSize, weight: .semibold))
                .foregroundColor(.urAmber)
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
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(verbatim: arrow)
                .font(.system(size: arrowSize, weight: .bold))
                .foregroundColor(worse ? Color.urAmber.opacity(0.75) : Color.white.opacity(0.55))
                .offset(y: -1)
            Text(verbatim: text)
                .font(.system(size: numberSize, weight: .semibold).monospacedDigit())
                .foregroundColor(worse ? Color.urAmber : themeManager.currentTheme.textColor)
                // with Reduce Motion the digits cross-fade instead of rolling
                .contentTransition(reduceMotion ? .opacity : .numericText())
        }
    }

    private static func label(_ label: SlowInternetPillContent.Label) -> Text {
        switch label {
        case .poorSignal:
            return Text("Poor signal")
        case .fallback:
            return Text("Fallback")
        }
    }
}

/// The pill's presence (apple/DELAY.md §3, §5.2). It appears with its first
/// square; the digits roll as the numbers change and the width eases. On a
/// return to normal the squares fade out from the inside while the green
/// check and "Internet back to normal" fade in; that holds 3 s, then the
/// pill fades. Leaving for any other reason, it waits until its last square
/// has started fading, then fades. Reduce Motion keeps the fades and drops
/// the slide.
///
/// The numbers move without a report, so while the pill shows them the store
/// re-reads them (`setPillVisible`).
struct SlowInternetPillHost: View {
    @EnvironmentObject var transportDelayStore: TransportDelayStore
    /// Something more severe has the top of the screen: the pill leaves,
    /// with no recovered state.
    var hidden = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How long "Internet back to normal" shows before the pill fades.
    private static let recoveredHold: TimeInterval = 3
    // the digits roll, the width eases and the copy cross-fades
    private static let contentChange = Animation.easeInOut(duration: 0.35)

    @State private var visible = false
    // what the pill shows, nil while it is not up or is leaving
    @State private var shown: SlowInternetPillContent? = nil
    // what the pill draws: it keeps the last content while it fades out
    @State private var content = SlowInternetPillContent(reading: .normal)
    @State private var shownLevel = 0
    @State private var exitTask: Task<Void, Never>? = nil

    var body: some View {
        ZStack {
            if visible {
                SlowInternetPill(level: shownLevel, content: content)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -6)))
            }
        }
        .onAppear {
            apply(animated: false)
        }
        .onChange(of: transportDelayStore.state) { _ in
            apply(animated: true)
        }
        .onChange(of: hidden) { _ in
            apply(animated: true)
        }
        .onDisappear {
            exitTask?.cancel()
            exitTask = nil
            transportDelayStore.setPillVisible(false)
        }
    }

    /// Unanimated (on appear), the pill shows what is there now: the slow
    /// content or nothing.
    private func apply(animated: Bool) {
        let state = transportDelayStore.state
        let previous = shown
        let next = SlowInternetPillContent.next(after: animated ? previous : nil, state: state, hidden: hidden)
        shown = next
        transportDelayStore.setPillVisible(next.map { !$0.recovered } ?? false)

        guard animated else {
            exitTask?.cancel()
            exitTask = nil
            shownLevel = next == nil ? 0 : state.level
            if let next {
                content = next
            }
            visible = next != nil
            return
        }
        guard let next else {
            // once: a pill already leaving keeps going
            if previous != nil {
                leave()
            }
            return
        }
        if next.recovered {
            if previous?.recovered != true {
                recover(next)
            }
            return
        }

        exitTask?.cancel()
        exitTask = nil
        shownLevel = state.level
        if !visible {
            content = next
            withAnimation(.easeOut(duration: TunnelMotion.fadeInDuration)) {
                visible = true
            }
        } else if next != content {
            withAnimation(Self.contentChange) {
                content = next
            }
        }
    }

    /// The squares fade out from the inside first; the pill follows once the
    /// last of them has started, keeping its copy.
    private func leave() {
        exitTask?.cancel()
        let exitDelay = TunnelMotion.containerExitDelay(fromDepth: TunnelGeometry.depth(level: shownLevel))
        shownLevel = 0
        exitTask = fadeOut(after: exitDelay)
    }

    /// The squares fade out from the inside as the check and "Internet back
    /// to normal" fade in; that holds, then the pill fades.
    private func recover(_ next: SlowInternetPillContent) {
        exitTask?.cancel()
        shownLevel = 0
        withAnimation(Self.contentChange) {
            content = next
        }
        exitTask = fadeOut(after: Self.recoveredHold)
    }

    private func fadeOut(after delay: TimeInterval) -> Task<Void, Never> {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else {
                return
            }
            shown = nil
            withAnimation(.easeOut(duration: TunnelMotion.fadeOutDuration)) {
                visible = false
            }
        }
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

#if os(iOS)
/// "Notify me when my internet is slow", in Settings: the tunnel extension's
/// notification (apple/DELAY.md §5.5, §6).
struct SlowInternetNotifyToggle: View {
    @EnvironmentObject var themeManager: ThemeManager
    @ObservedObject private var preference = TransportDelayLiveActivityPreference.shared

    var body: some View {
        UrSwitchToggle(
            isOn: Binding(
                get: { preference.enabled },
                set: { preference.setEnabled($0) }
            )
        ) {
            Text("Notify me when my internet is slow")
                .font(themeManager.currentTheme.bodyFont)
                .foregroundColor(themeManager.currentTheme.textColor)
        }
    }
}

/// The connect screen's pill, top right (apple/DELAY.md §5.2). Hidden while
/// the can't-reach banner shows: the banner is the more severe state and
/// sits at the top too.
struct SlowInternetPillOverlay: View {
    @ObservedObject private var cantReachPrompt = CantReachUrnetworkPrompt.shared

    var body: some View {
        SlowInternetPillHost(hidden: cantReachPrompt.visible)
    }
}
#endif

#if os(macOS)
/// The connect window's toolbar pill (apple/DELAY.md §5.3): the same pill,
/// a readout here too.
struct SlowInternetToolbarPill: View {
    var body: some View {
        SlowInternetPillHost()
            .help(Text("Slow internet"))
    }
}

/// The menu bar extra's "Slow internet" row (apple/DELAY.md §5.3), from a
/// store that lives outside DeviceStores (they reset when the window hides)
/// and draws its cached values: the menu makes no sdk call.
struct SlowInternetMenuBarRow: View {
    let state: TransportDelayState

    var body: some View {
        if 0 < state.level {
            Button(action: {}) {
                HStack {
                    if let image = TunnelIndicatorMenuImage.image(depth: TunnelGeometry.depth(level: state.level)) {
                        Image(nsImage: image)
                    }
                    if state.fallback {
                        Text("Fallback connection")
                    } else {
                        Text("Slow internet")
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(true)
        }
    }
}

/// The tunnel as a template image, for the menu bar extra's menu, where a
/// row draws only an image and its text. One per depth, rendered once.
@MainActor
enum TunnelIndicatorMenuImage {
    static let size: CGFloat = 16

    private static var cache: [Int: NSImage] = [:]

    static func image(depth: Int) -> NSImage? {
        if let image = cache[depth] {
            return image
        }
        let renderer = ImageRenderer(content: TunnelIndicator(depth: depth, size: size, color: .black))
        renderer.scale = 2
        guard let image = renderer.nsImage else {
            return nil
        }
        image.isTemplate = true
        cache[depth] = image
        return image
    }
}
#endif
