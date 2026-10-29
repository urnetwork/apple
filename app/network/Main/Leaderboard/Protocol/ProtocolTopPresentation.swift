//
//  ProtocolTopPresentation.swift
//  URnetwork
//
//  What the Protocol leaderboard says, as plain values: the numbers, the
//  label chips, the banners, the claim prompt's state, the names rows and
//  the card show, the 200 line and the progress chart's points. Pure, so it
//  is tested without a view. Every string is the stored English of a
//  localizations key (apple/LEADERTOP.md §10), looked up by its text.
//

import Foundation

/// Numbers as the board shows them.
enum ProtocolFormat {

    /// "41.2": a score, with one decimal and the locale's separators.
    static func score(_ value: Double, locale: Locale = .current) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 1
        formatter.maximumFractionDigits = 1
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.1f", value)
    }

    /// "12%": the size of a fraction, whole percents, and one decimal under
    /// 1% so a network just over the line does not read "0%".
    static func percent(_ fraction: Double, locale: Locale = .current) -> String {
        let size = abs(fraction)
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .percent
        let underOne = size > 0 && size * 100 < 0.95
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = underOne ? 1 : 0
        return formatter.string(from: NSNumber(value: size)) ?? "\(Int((size * 100).rounded()))%"
    }

    /// "41,230"
    static func count(_ value: Int, locale: Locale = .current) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// "#173"
    static func rank(_ position: Int, locale: Locale = .current) -> String {
        PointsLeaderboardIndicator.rankText(Int64(position), locale: locale)
    }

    /// "+12%" above the line, "−8%" below it: the margin with its sign.
    static func signedPercent(_ fraction: Double, locale: Locale = .current) -> String {
        (fraction >= 0 ? "+" : "\u{2212}") + percent(fraction, locale: locale)
    }
}

/// The board's strings, from the string catalog.
enum ProtocolText {

    static var tab: String {
        String(localized: "Protocol")
    }

    static var bannerClosed: String {
        String(localized: "Claiming isn't open yet. You can see where you'd rank now.")
    }

    /// "Rankings last updated 4 hours ago."
    static func bannerStale(computedAt: Date, now: Date, locale: Locale = .current) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .full
        let time = formatter.localizedString(for: computedAt, relativeTo: now)
        return String(localized: "Rankings last updated \(time).")
    }

    static var projected: String {
        String(localized: "projected")
    }

    static func ofRanked(_ count: Int) -> String {
        String(localized: "of \(count) ranked networks")
    }

    /// "12% above the Top 200 line", "8% below the Top 200 line"
    static func margin(_ margin: Double, locale: Locale = .current) -> String {
        let percent = ProtocolFormat.percent(margin, locale: locale)
        if margin >= 0 {
            return String(localized: "\(percent) above the Top 200 line")
        }
        return String(localized: "\(percent) below the Top 200 line")
    }

    /// "up 9 since the last update"; nil when the position did not move.
    static func trend(_ trend: Int) -> String? {
        if trend > 0 {
            return String(localized: "up \(trend) since the last update")
        }
        if trend < 0 {
            let count = -trend
            return String(localized: "down \(count) since the last update")
        }
        return nil
    }

    static func why(prefixes: Int, shared: Int) -> String {
        String(localized: "Distinct IP prefixes: \(prefixes). Shared with other networks: \(shared).")
    }

    static func solo(_ score: Double, locale: Locale = .current) -> String {
        let text = ProtocolFormat.score(score, locale: locale)
        return String(localized: "If you claimed alone today: \(text).")
    }

    static var you: String {
        String(localized: "You")
    }

    static func label(_ label: SnTopLabel) -> String {
        switch label {
        case .estimate:
            return String(localized: "Estimate")
        case .likely:
            return String(localized: "Likely")
        case .borderline:
            return String(localized: "Borderline")
        case .unlikely:
            return String(localized: "Unlikely")
        case .notMeasurable:
            return String(localized: "Not measurable")
        }
    }

    static var chartTitle: String {
        String(localized: "Projected rank, last 90 days")
    }

    static var chartLine: String {
        String(localized: "Top 200 line")
    }

    static func chartAccessibility(rank: Int) -> String {
        String(localized: "Projected rank over 90 days, now \(rank)")
    }

    static var claimInside: String {
        String(localized: "You're projected in the top 200.")
    }

    static var claimButton: String {
        String(localized: "Claim on Earnings")
    }

    static var claimSoon: String {
        String(localized: "Claiming opens soon on the Earnings page.")
    }

    static var claimBorderline: String {
        String(localized: "You're close to the line, and rankings change every tempo.")
    }

    static var claimWarning: String {
        String(localized: "A claimed fleet that ranks 201 or lower earns nothing.")
    }

    /// Why the validator cannot score the network; nil for no reason, or
    /// one this app does not know (the chip still says "Not measurable").
    static func notMeasurable(_ reason: SnTopNotMeasurableReason) -> String? {
        switch reason {
        case .notInCohort:
            return String(localized: "Your devices aren't measured by the validator yet.")
        case .sharedEgress:
            return String(localized: "Your devices share an IP with another network.")
        case .notProviding:
            return String(localized: "Turn on providing to be ranked.")
        case .none, .other:
            return nil
        }
    }

    static func line(cutoff: Double, locale: Locale = .current) -> String {
        let score = ProtocolFormat.score(cutoff, locale: locale)
        return String(localized: "Top 200 line · score \(score)")
    }

    static func lineAccessibility(cutoff: Double, locale: Locale = .current) -> String {
        let score = ProtocolFormat.score(cutoff, locale: locale)
        return String(localized: "Top 200 line, score \(score)")
    }

    static func uid(_ uid: Int64) -> String {
        String(localized: "UID \(uid)")
    }

    static var explainer: String {
        String(localized: "Ranked the way the SN25 validator picks its Top 200: by how many distinct IP prefixes your devices provide from, with shared prefixes split between the networks on them. Updated about every 72 minutes. These are projections until you claim.")
    }

    static var empty: String {
        String(localized: "Rankings will appear after the next update.")
    }

    static var anonymous: String {
        String(localized: "Anonymous")
    }

    // MARK: the claimed detail sheet

    static var detailClaimed: String {
        String(localized: "claimed")
    }

    static var detailProjectedRank: String {
        String(localized: "Projected rank")
    }

    static var detailValidatorRank: String {
        String(localized: "Validator rank")
    }

    static func detailValidatorRankValue(rank: Int, of count: Int) -> String {
        String(localized: "#\(rank) of \(count) claimed")
    }

    static var detailValidatorScore: String {
        String(localized: "Validator score")
    }

    static var detailReplicaScore: String {
        String(localized: "Board replica score")
    }

    static var detailIncentive: String {
        String(localized: "On-chain incentive")
    }

    static var detailStale: String {
        String(localized: "stale")
    }

    static var detailGeneration: String {
        String(localized: "Generation")
    }

    static var detailValidUntil: String {
        String(localized: "Claim valid until")
    }

    static func detailEpoch(_ epoch: Int64) -> String {
        String(localized: "Epoch \(epoch)")
    }

    static var detailSelected: String {
        String(localized: "Selected")
    }

    static var detailNotSelected: String {
        String(localized: "Not selected")
    }

    static var detailIncentiveNote: String {
        String(localized: "On-chain incentive lags the validator's ranking.")
    }

    // MARK: the Earnings tile

    /// "projected · +12%"
    static func earningsProjected(margin: Double, locale: Locale = .current) -> String {
        let text = ProtocolFormat.signedPercent(margin, locale: locale)
        return String(localized: "projected · \(text)")
    }

    static var earningsBody: String {
        String(localized: "Ranked like the SN25 validator's Top 200, by the distinct IP prefixes your devices provide from. Head miners earn SN25α every tempo.")
    }

    static var earningsClaimingSoon: String {
        String(localized: "Claiming opens soon")
    }

    static var earningsClaimingSoonBody: String {
        String(localized: "We'll let you know when you can claim your spot. A claimed fleet that ranks 201 or lower earns nothing.")
    }

    static var earningsSeeBoard: String {
        String(localized: "See the Protocol leaderboard")
    }
}

/// A banner on top of the tab (apple/LEADERTOP.md §4).
enum ProtocolBanner: Equatable, Hashable {
    /// fleet binding is closed on mainnet: the neutral note
    case bindingClosed
    /// the snapshot was computed more than 3 tempos ago
    case stale(computedAt: Date)

    /// The banners of a snapshot, closed first; none before one has loaded.
    static func of(_ snapshot: SnTopSnapshotInfo?) -> [ProtocolBanner] {
        guard let snapshot else {
            return []
        }
        var banners: [ProtocolBanner] = []
        if !snapshot.bindingOpen {
            banners.append(.bindingClosed)
        }
        if snapshot.stale, let computedAt = snapshot.computedAt {
            banners.append(.stale(computedAt: computedAt))
        }
        return banners
    }
}

/// The claim prompt on the own-status card (apple/LEADERTOP.md §5; Q5, Q13, Q16).
enum ProtocolClaimPrompt: Equatable {
    case hidden
    /// binding is open: the Claim on Earnings button
    case claim(close: Bool)
    /// binding is closed: the note that claiming opens soon, no button
    case soon(close: Bool)

    /// within this fraction of the line a network is close to it (M, Q13)
    static let closeMargin = 0.20

    /**
     * Only a measurable network projected inside the top 200 is prompted,
     * and one that has claimed already is not asked to claim. `close` adds
     * the "close to the line" warning: the label says borderline, or, while
     * every row reads "estimate" (Q17), the margin is within 20% of the line.
     */
    static func of(row: SnTopRowInfo?, bindingOpen: Bool) -> ProtocolClaimPrompt {
        guard let row,
              row.claimPrompt,
              row.measurable,
              1 <= row.position && row.position <= 200,
              !row.claimed else {
            return .hidden
        }
        let close = isClose(row)
        return bindingOpen ? .claim(close: close) : .soon(close: close)
    }

    static func isClose(_ row: SnTopRowInfo) -> Bool {
        switch row.label {
        case .borderline:
            return true
        case .estimate, nil:
            return abs(row.margin) < closeMargin
        case .likely, .unlikely, .notMeasurable:
            return false
        }
    }
}

/// How a network is named on the board.
enum ProtocolName: Equatable {
    case name(String)
    case anonymous
    /// an anonymous claimed network, by its fleets' UIDs (Q12)
    case uids([Int64])

    /// A row: its name when it opted in, else its fleets' UIDs when it has
    /// claimed, else Anonymous.
    static func of(_ row: SnTopRowInfo) -> ProtocolName {
        let name = row.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
            return .name(name)
        }
        if !row.fleets.isEmpty {
            return .uids(row.fleets.map(\.uid))
        }
        return .anonymous
    }

    /**
     * The own-status card's header: the network's name while it shows its
     * name on the boards ("Show my network name", points_leaderboard_public,
     * Q12), else Anonymous, as others see it. The row's name can trail a
     * switch just turned on by a tempo, so the session's name stands in.
     */
    static func own(isPublic: Bool, rowName: String, sessionName: String) -> ProtocolName {
        guard isPublic else {
            return .anonymous
        }
        let name = rowName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
            return .name(name)
        }
        let session = sessionName.trimmingCharacters(in: .whitespacesAndNewlines)
        return session.isEmpty ? .anonymous : .name(session)
    }

    var text: String {
        switch self {
        case .name(let name):
            return name
        case .anonymous:
            return ProtocolText.anonymous
        case .uids(let uids):
            return uids.map { ProtocolText.uid($0) }.joined(separator: ", ")
        }
    }

    var isAnonymous: Bool {
        self == .anonymous
    }
}

/// The 200 line in the ranked list (apple/LEADERTOP.md §6).
enum ProtocolLine {

    static let position = 200

    /// Rows above the line get a faint accent tint.
    static func isAbove(_ position: Int) -> Bool {
        1 <= position && position <= Self.position
    }

    /// The divider follows row 200.
    static func follows(_ position: Int) -> Bool {
        position == Self.position
    }
}

/// What VoiceOver reads for a row: the caller first, then the rank, the
/// name, the score and its trend, the claimed UIDs, and the label on the
/// caller's own row or "Not measurable" on a dimmed one.
enum ProtocolRowAccessibility {

    static func label(_ row: SnTopRowInfo, locale: Locale = .current) -> String {
        var parts: [String] = []
        if row.isMe {
            parts.append(ProtocolText.you)
        }
        parts.append(ProtocolFormat.rank(row.position, locale: locale))
        parts.append(ProtocolName.of(row).text)
        parts.append(ProtocolFormat.score(row.projectedScore, locale: locale))
        if let trend = ProtocolText.trend(row.trend) {
            parts.append(trend)
        }
        if row.claimed, ProtocolName.of(row) != .uids(row.fleets.map(\.uid)) {
            parts.append(row.fleets.map { ProtocolText.uid($0.uid) }.joined(separator: ", "))
        }
        if row.isMe, let label = row.label {
            parts.append(ProtocolText.label(label))
        } else if !row.measurable {
            parts.append(ProtocolText.label(.notMeasurable))
        }
        return parts.joined(separator: ", ")
    }
}

/// One day on the progress chart.
struct ProtocolChartPoint: Equatable, Identifiable {
    let date: Date
    let rank: Int

    var id: Date {
        date
    }
}

/// The progress chart (Q11): the daily projected rank, the y axis inverted
/// so up is better, with the 200 line across.
enum ProtocolChart {

    /// The history as points: days that parse and rank, oldest first, the
    /// last 90.
    static func points(_ history: [SnTopHistoryPointInfo]) -> [ProtocolChartPoint] {
        var byDay: [Date: Int] = [:]
        for point in history where point.rank > 0 {
            if let date = SnTopTime.day(point.day) {
                byDay[date] = point.rank
            }
        }
        let points = byDay
            .map { ProtocolChartPoint(date: $0.key, rank: $0.value) }
            .sorted { $0.date < $1.date }
        return Array(points.suffix(90))
    }

    /// The ranks the y axis spans: every point and the line, with room
    /// around them, never above rank 1.
    static func rankDomain(_ points: [ProtocolChartPoint], line: Int = ProtocolLine.position) -> ClosedRange<Int> {
        let ranks = points.map(\.rank) + [line]
        let low = ranks.min() ?? line
        let high = ranks.max() ?? line
        let pad = max(5, (high - low) / 10)
        return max(1, low - pad)...(high + pad)
    }

    /// The point nearest a day, for the chart's tap.
    static func nearest(_ points: [ProtocolChartPoint], to date: Date) -> ProtocolChartPoint? {
        points.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
    }
}
