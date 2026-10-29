//
//  ProtocolClaimedDetailSheet.swift
//  URnetwork
//
//  A claimed network's detail (apple/LEADERTOP.md §6): per fleet, the UID
//  and generation and the epoch its claim is valid until, the validator's
//  rank and score and whether it was selected this tempo (Q9), the on-chain
//  incentive, "stale" when flagged (Q10), and the board's replica score.
//

import SwiftUI

/// One line of the sheet.
struct ProtocolDetailFact: Equatable, Identifiable {
    let label: String
    let value: String

    var id: String {
        label
    }
}

/// The sheet's facts, pure so they are tested without a view.
enum ProtocolClaimedDetail {

    /// A fleet's facts, in the sheet's order; the validator's and the
    /// chain's only when they are known.
    static func facts(row: SnTopRowInfo, fleet: SnTopFleetInfo, locale: Locale = .current) -> [ProtocolDetailFact] {
        var facts: [ProtocolDetailFact] = [
            ProtocolDetailFact(label: ProtocolText.detailProjectedRank, value: ProtocolFormat.rank(row.position, locale: locale)),
        ]
        if let rank = fleet.validatorRank {
            let value = fleet.validatorRankOf.map { ProtocolText.detailValidatorRankValue(rank: rank, of: $0) }
                ?? ProtocolFormat.rank(rank, locale: locale)
            facts.append(ProtocolDetailFact(label: ProtocolText.detailValidatorRank, value: value))
        }
        if let score = fleet.validatorScore {
            facts.append(ProtocolDetailFact(label: ProtocolText.detailValidatorScore, value: ProtocolFormat.score(score, locale: locale)))
        }
        facts.append(ProtocolDetailFact(label: ProtocolText.detailReplicaScore, value: ProtocolFormat.score(fleet.replicaScore, locale: locale)))
        if let incentive = fleet.incentive {
            var value = incentivePercent(incentive, locale: locale)
            if fleet.incentiveStale {
                value += " · " + ProtocolText.detailStale
            }
            facts.append(ProtocolDetailFact(label: ProtocolText.detailIncentive, value: value))
        }
        facts.append(ProtocolDetailFact(label: ProtocolText.detailGeneration, value: ProtocolFormat.count(Int(fleet.generation), locale: locale)))
        facts.append(ProtocolDetailFact(label: ProtocolText.detailValidUntil, value: ProtocolText.detailEpoch(fleet.validToEpoch)))
        return facts
    }

    /// The incentive, a fraction of the subnet's, as a percent: "1.8%".
    static func incentivePercent(_ fraction: Double, locale: Locale = .current) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .percent
        formatter.minimumFractionDigits = 1
        formatter.maximumFractionDigits = 1
        return formatter.string(from: NSNumber(value: fraction)) ?? String(format: "%.1f%%", fraction * 100)
    }

    /// "Selected" or "Not selected", when the validator's summary says.
    static func selection(_ fleet: SnTopFleetInfo) -> String? {
        guard let selected = fleet.selected else {
            return nil
        }
        return selected ? ProtocolText.detailSelected : ProtocolText.detailNotSelected
    }
}

struct ProtocolClaimedDetailSheet: View {

    @EnvironmentObject var themeManager: ThemeManager

    let row: SnTopRowInfo
    let dismiss: () -> Void

    var body: some View {
        let name = ProtocolName.of(row)

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    if !row.tag.isEmpty {
                        Text(verbatim: row.tag)
                            .font(.system(size: 20))
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(themeManager.currentTheme.accentColor.opacity(0.25)))
                            .accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: row.fleets.map { ProtocolText.uid($0.uid) }.joined(separator: ", "))
                            .font(themeManager.currentTheme.secondaryTitleFont)
                            .foregroundStyle(themeManager.currentTheme.textColor)
                            .lineLimit(2)
                            .accessibilityAddTraits(.isHeader)
                        Text(verbatim: subtitle(name))
                            .font(themeManager.currentTheme.secondaryBodyFont)
                            .foregroundStyle(themeManager.currentTheme.textMutedColor)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }

                ForEach(row.fleets) { fleet in
                    fleetSection(fleet, showsUid: row.fleets.count > 1)
                }

                if row.fleets.contains(where: { $0.incentive != nil }) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.urAmber)
                            .accessibilityHidden(true)
                        Text(verbatim: ProtocolText.detailIncentiveNote)
                            .font(themeManager.currentTheme.secondaryBodyFont)
                            .foregroundStyle(themeManager.currentTheme.textMutedColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                UrButton(
                    text: "Close",
                    action: dismiss,
                    style: .outlineSecondary,
                    accessibilityIdentifier: "leaderboard.protocol.detail.close"
                )
            }
            .padding(20)
        }
        .background(themeManager.currentTheme.backgroundColor)
    }

    /// "kayak-hollow · claimed", or "Anonymous · claimed"
    private func subtitle(_ name: ProtocolName) -> String {
        let shown: String
        switch name {
        case .name(let text):
            shown = text
        case .anonymous, .uids:
            shown = ProtocolText.anonymous
        }
        return shown + " · " + ProtocolText.detailClaimed
    }

    private func fleetSection(_ fleet: SnTopFleetInfo, showsUid: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if showsUid {
                    ProtocolUidBadge(uid: fleet.uid)
                }
                Spacer(minLength: 0)
                if let selection = ProtocolClaimedDetail.selection(fleet) {
                    Text(verbatim: selection)
                        .font(themeManager.currentTheme.secondaryBodyFont.weight(.semibold))
                        .foregroundStyle(fleet.selected == true ? Color.urGreen : themeManager.currentTheme.textMutedColor)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(fleet.selected == true ? Color.urGreen.opacity(0.12) : Color.clear))
                        .overlay(Capsule().stroke(
                            fleet.selected == true ? Color.urGreen.opacity(0.45) : themeManager.currentTheme.borderEmphasisColor,
                            lineWidth: 1
                        ))
                }
            }
            VStack(spacing: 0) {
                let facts = ProtocolClaimedDetail.facts(row: row, fleet: fleet)
                ForEach(Array(facts.enumerated()), id: \.element.id) { index, fact in
                    if index > 0 {
                        Divider()
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(verbatim: fact.label)
                            .font(themeManager.currentTheme.secondaryBodyFont)
                            .foregroundStyle(themeManager.currentTheme.textMutedColor)
                        Spacer(minLength: 8)
                        Text(verbatim: fact.value)
                            .font(themeManager.currentTheme.bodyFont.weight(.semibold))
                            .foregroundStyle(themeManager.currentTheme.textColor)
                            .monospacedDigit()
                            .multilineTextAlignment(.trailing)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .accessibilityElement(children: .combine)
                }
            }
            .background(themeManager.currentTheme.tintedBackgroundBase)
            .cornerRadius(12)
        }
    }
}
