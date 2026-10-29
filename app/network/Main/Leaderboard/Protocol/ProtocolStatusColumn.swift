//
//  ProtocolStatusColumn.swift
//  URnetwork
//
//  The top of the Protocol tab (apple/LEADERTOP.md §4, §5, §7): the status
//  banner, the caller's own-status card and the explainer. It leads the list
//  at compact width and fills the second pane in a regular-width window.
//

import Charts
import SwiftUI

struct ProtocolStatusColumn: View {

    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var deviceManager: DeviceManager

    @ObservedObject var store: ProtocolTopStore
    @ObservedObject var pointsStore: PointsLeaderboardStore
    let claimOnEarnings: () -> Void

    var body: some View {
        let state = store.state
        let snapshot = state.currentSnapshot

        VStack(alignment: .leading, spacing: 12) {
            if snapshot == nil && state.listContent == .loading {
                // a banner the size of the real one until the snapshot says
                Skeleton(height: 40, cornerRadius: 10)
                    .skeletonGroup("Loading...")
            }
            ForEach(ProtocolBanner.of(snapshot), id: \.self) { banner in
                ProtocolBannerView(banner: banner)
            }

            ProtocolOwnStatusCard(
                content: state.cardContent,
                snapshot: state.meSnapshot ?? state.snapshot,
                pointsStore: pointsStore,
                sessionName: deviceManager.parsedJwt?.networkName ?? "",
                retry: {
                    store.retryMe()
                },
                nameChanged: {
                    store.refresh()
                },
                claimOnEarnings: claimOnEarnings
            )

            Text(verbatim: ProtocolText.explainer)
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundStyle(themeManager.currentTheme.textMutedColor)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One banner, in the neutral style: binding is closed, or the rankings are
/// stale.
struct ProtocolBannerView: View {

    @EnvironmentObject var themeManager: ThemeManager

    let banner: ProtocolBanner

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.urLightBlue)
                .accessibilityHidden(true)
            TimelineView(.periodic(from: .now, by: 60)) { context in
                Text(verbatim: text(now: context.date))
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundStyle(themeManager.currentTheme.textColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(themeManager.currentTheme.accentColor.opacity(0.18))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(themeManager.currentTheme.accentColor.opacity(0.45), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }

    private var icon: String {
        switch banner {
        case .bindingClosed:
            return "info.circle"
        case .stale:
            return "clock"
        }
    }

    private func text(now: Date) -> String {
        switch banner {
        case .bindingClosed:
            return ProtocolText.bannerClosed
        case .stale(let computedAt):
            return ProtocolText.bannerStale(computedAt: computedAt, now: now)
        }
    }
}

/**
 * The caller's network on the board (GET /sn/top/me): its tag and name (or
 * Anonymous) with the "Show my network name" switch shared with Points, the
 * projected position, the margin to the 200 line with the trend, the label
 * chip, the 90-day progress chart, why it scores what it does, and the claim
 * prompt when it is measurable and projected inside the top 200, or why the
 * validator cannot measure it.
 */
struct ProtocolOwnStatusCard: View {

    @EnvironmentObject var themeManager: ThemeManager

    let content: ProtocolCardContent
    let snapshot: SnTopSnapshotInfo?
    @ObservedObject var pointsStore: PointsLeaderboardStore
    /// the session's network name, while the row's trails a switch just turned on
    let sessionName: String
    let retry: () -> Void
    /// the switch changed: the board reloads with the name shown or hidden
    let nameChanged: () -> Void
    let claimOnEarnings: () -> Void

    var body: some View {
        switch content {
        case .signedOut:
            EmptyView()
        case .loading:
            placeholder
        case .failed:
            SectionLoadFailedView(retry: retry)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(themeManager.currentTheme.tintedBackgroundBase)
                .cornerRadius(12)
        case .loaded(let me):
            card(me)
        }
    }

    private func card(_ me: SnTopMeInfo) -> some View {
        let row = me.rankedRow
        let name = ProtocolName.own(
            isPublic: pointsStore.isPointsPublic,
            rowName: me.row?.name ?? "",
            sessionName: sessionName
        )
        let tag = (me.row?.tag).flatMap { $0.isEmpty ? nil : $0 } ?? pointsStore.emojiTag
        let chartPoints = ProtocolChart.points(me.history)

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if !tag.isEmpty {
                    Text(verbatim: tag)
                        .font(.system(size: 18))
                        .lineLimit(1)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(themeManager.currentTheme.accentColor.opacity(0.25)))
                        .accessibilityHidden(true)
                }
                Text(verbatim: name.text)
                    .font(themeManager.currentTheme.bodyFont.weight(.bold))
                    .foregroundStyle(name.isAnonymous
                        ? themeManager.currentTheme.textMutedColor
                        : themeManager.currentTheme.textColor)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }

            UrSwitchToggle(
                isOn: Binding(
                    get: { pointsStore.isPointsPublic },
                    set: { _ in pointsStore.togglePointsPublic(onChanged: nameChanged) }
                ),
                // the switch reads the network's setting once the points
                // board has answered; until then it would show off
                isEnabled: !pointsStore.isSettingPublic && pointsStore.me != nil
            ) {
                Text("Show my network name")
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundStyle(themeManager.currentTheme.textColor)
            }

            if let row {
                standing(row)
            }

            if !chartPoints.isEmpty {
                ProtocolRankChart(points: chartPoints, currentRank: row?.position)
            }

            if row != nil || me.distinctPrefixes > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: ProtocolText.why(prefixes: me.distinctPrefixes, shared: me.sharedPrefixes))
                    Text(verbatim: ProtocolText.solo(me.soloScore))
                }
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundStyle(themeManager.currentTheme.textMutedColor)
                .fixedSize(horizontal: false, vertical: true)
            }

            notMeasurable(me)

            claimPrompt(row)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(themeManager.currentTheme.tintedBackgroundBase)
        .cornerRadius(12)
        .accessibilityIdentifier("leaderboard.protocol.card")
    }

    /// "#173 projected", "of 41,230 ranked networks", then the chip, the
    /// margin to the line and the trend.
    private func standing(_ row: SnTopRowInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: ProtocolFormat.rank(row.position))
                    .font(themeManager.currentTheme.titleCondensedFont)
                    .foregroundStyle(themeManager.currentTheme.textColor)
                Text(verbatim: ProtocolText.projected)
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundStyle(themeManager.currentTheme.textMutedColor)
            }
            if let snapshot, snapshot.totalRanked > 0 {
                Text(verbatim: ProtocolText.ofRanked(snapshot.totalRanked))
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundStyle(themeManager.currentTheme.textMutedColor)
            }
            ProtocolFlowRow(spacing: 8) {
                if let label = row.label {
                    ProtocolLabelChip(label: label)
                }
                Text(verbatim: ProtocolText.margin(row.margin))
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundStyle(themeManager.currentTheme.textColor)
                if let trend = ProtocolText.trend(row.trend) {
                    HStack(spacing: 4) {
                        ProtocolTrendGlyph(trend: row.trend)
                        Text(verbatim: trend)
                            .font(themeManager.currentTheme.secondaryBodyFont)
                            .foregroundStyle(row.trend > 0 ? Color.urLightBlue : Color.urAmber)
                    }
                }
            }
        }
    }

    /// Why the validator cannot score the network, and what helps.
    @ViewBuilder
    private func notMeasurable(_ me: SnTopMeInfo) -> some View {
        if let reason = ProtocolText.notMeasurable(me.notMeasurableReason) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "eye.slash")
                    .font(.system(size: 13))
                    .foregroundStyle(themeManager.currentTheme.textMutedColor)
                    .accessibilityHidden(true)
                Text(verbatim: reason)
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundStyle(themeManager.currentTheme.textColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /**
     * Open: a note and the screen's one primary button, Claim on Earnings.
     * Closed: the note that claiming opens soon, nothing to tap. Close to
     * the line adds its warning, and every prompt says a fleet ranked 201 or
     * lower earns nothing.
     */
    @ViewBuilder
    private func claimPrompt(_ row: SnTopRowInfo?) -> some View {
        let prompt = ProtocolClaimPrompt.of(row: row, bindingOpen: snapshot?.bindingOpen ?? false)
        switch prompt {
        case .hidden:
            EmptyView()
        case .claim(let close), .soon(let close):
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: ProtocolText.claimInside)
                    .font(themeManager.currentTheme.bodyFont.weight(.semibold))
                    .foregroundStyle(themeManager.currentTheme.textColor)
                    .fixedSize(horizontal: false, vertical: true)
                if case .soon = prompt {
                    Text(verbatim: ProtocolText.claimSoon)
                        .font(themeManager.currentTheme.secondaryBodyFont)
                        .foregroundStyle(themeManager.currentTheme.textColor)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    UrButton(
                        text: "Claim on Earnings",
                        action: claimOnEarnings,
                        accessibilityIdentifier: "leaderboard.protocol.claim"
                    )
                }
                if close {
                    Text(verbatim: ProtocolText.claimBorderline)
                        .font(themeManager.currentTheme.secondaryBodyFont)
                        .foregroundStyle(Color.urAmber)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(verbatim: ProtocolText.claimWarning)
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundStyle(themeManager.currentTheme.textMutedColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(themeManager.currentTheme.backgroundColor.opacity(0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(themeManager.currentTheme.borderBaseColor, lineWidth: 1)
            )
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("leaderboard.protocol.prompt")
        }
    }

    /// The card's boxes at their loaded sizes.
    private var placeholder: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Skeleton(width: 36, height: 36, cornerRadius: 18)
                Skeleton(width: 140, height: 16)
            }
            HStack {
                Skeleton(width: 170, height: 14)
                Spacer(minLength: 0)
                Skeleton(width: 44, height: 26, cornerRadius: 13)
            }
            Skeleton(width: 96, height: 32)
            Skeleton(width: 180, height: 14)
            HStack(spacing: 8) {
                Skeleton(width: 72, height: 22, cornerRadius: 11)
                Skeleton(width: 170, height: 14)
            }
            Skeleton(height: ProtocolRankChart.height + 20, cornerRadius: 8)
            Skeleton(height: 14)
            Skeleton(width: 200, height: 14)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(themeManager.currentTheme.tintedBackgroundBase)
        .cornerRadius(12)
        .skeletonGroup("Loading...")
    }
}

/// Lays its children out in a row and wraps them to the next line when the
/// row is full, so the chip, the margin and the trend never truncate.
struct ProtocolFlowRow: Layout {

    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if x > 0 && x + size.width > width {
                y += lineHeight + spacing
                x = 0
                lineHeight = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: min(widest, width), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            if x > bounds.minX && x + size.width > bounds.maxX {
                y += lineHeight + spacing
                x = bounds.minX
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

/**
 * The network's daily projected rank over 90 days (Q11): a line with the y
 * axis inverted so up is better, the 200 line across, and the day's rank on
 * a tap. VoiceOver reads one summary.
 */
struct ProtocolRankChart: View {

    @EnvironmentObject var themeManager: ThemeManager

    let points: [ProtocolChartPoint]
    /// the network's rank now, for the summary
    let currentRank: Int?

    static let height: CGFloat = 120

    @State private var selected: ProtocolChartPoint? = nil

    var body: some View {
        // ranks plot negated, so the better rank is higher on the chart
        let domain = ProtocolChart.rankDomain(points)
        let summaryRank = currentRank ?? points.last?.rank ?? 0

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(verbatim: ProtocolText.chartTitle)
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundStyle(themeManager.currentTheme.textMutedColor)
                Spacer(minLength: 0)
                if let selected {
                    Text(verbatim: ProtocolFormat.rank(selected.rank) + " · " + selected.date.formatted(.dateTime.month(.abbreviated).day()))
                        .font(themeManager.currentTheme.secondaryBodyFont.weight(.semibold))
                        .foregroundStyle(themeManager.currentTheme.textColor)
                }
            }

            Chart {
                RuleMark(y: .value("Rank", -ProtocolLine.position))
                    .foregroundStyle(Color.urLightBlue.opacity(0.75))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .annotation(position: .top, alignment: .trailing) {
                        Text(verbatim: ProtocolText.chartLine)
                            .font(.system(size: 10))
                            .foregroundStyle(themeManager.currentTheme.textMutedColor)
                    }
                ForEach(points) { point in
                    LineMark(
                        x: .value("Day", point.date, unit: .day),
                        y: .value("Rank", -point.rank)
                    )
                    .foregroundStyle(themeManager.currentTheme.textColor)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineJoin: .round))
                }
                if let last = points.last {
                    PointMark(
                        x: .value("Day", last.date, unit: .day),
                        y: .value("Rank", -last.rank)
                    )
                    .foregroundStyle(Color.urGreen)
                    .symbolSize(36)
                }
                if let selected {
                    RuleMark(x: .value("Day", selected.date, unit: .day))
                        .foregroundStyle(themeManager.currentTheme.textMutedColor.opacity(0.6))
                    PointMark(
                        x: .value("Day", selected.date, unit: .day),
                        y: .value("Rank", -selected.rank)
                    )
                    .foregroundStyle(themeManager.currentTheme.textColor)
                    .symbolSize(48)
                }
            }
            .chartYScale(domain: (-domain.upperBound)...(-domain.lowerBound))
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine()
                        .foregroundStyle(themeManager.currentTheme.borderBaseColor)
                    AxisValueLabel {
                        if let rank = value.as(Int.self) {
                            Text(verbatim: ProtocolFormat.rank(-rank))
                                .font(.system(size: 10))
                                .foregroundStyle(themeManager.currentTheme.textMutedColor)
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                        .foregroundStyle(themeManager.currentTheme.textMutedColor)
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle()
                        .fill(Color.clear)
                        .contentShape(Rectangle())
                        .gesture(
                            SpatialTapGesture()
                                .onEnded { value in
                                    let origin = geometry[proxy.plotAreaFrame].origin
                                    if let date: Date = proxy.value(atX: value.location.x - origin.x) {
                                        let nearest = ProtocolChart.nearest(points, to: date)
                                        selected = nearest == selected ? nil : nearest
                                    }
                                }
                        )
                }
            }
            .frame(height: Self.height)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: ProtocolText.chartAccessibility(rank: summaryRank)))
        .accessibilityIdentifier("leaderboard.protocol.chart")
    }
}
