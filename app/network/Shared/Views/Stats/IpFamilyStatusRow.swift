//
//  IpFamilyStatusRow.swift
//  URnetwork
//

import SwiftUI
import URnetworkSdk

/**
 * The address families of the window's providers, as one row of three
 * columns under the transport bar: Dualstack, IPv4 and IPv6 (connect/IPV6.md
 * D2). Each column is a provider category, never a capability, so a dualstack
 * provider counts once, under Dualstack.
 *
 * A column is its label in the pixel face over its status: the providers
 * connected (Added) and connecting (InEvaluation) in that category, one line
 * each and only when the count is not zero, or "disconnected" when both are.
 * Providers that failed evaluation, were not added, or are on their way out
 * count as nothing.
 *
 * The columns rank the families: dualstack carries both, IPv4 and IPv6 tie
 * below it. The best of the columns with a connected provider is bright (the
 * theme's text color, shared on a tie), the other columns with anything
 * connected or connecting are dimmed (muted), and a column with nothing is
 * dimmed out (faint). The whole column takes its tier, label and status lines
 * alike, so the row reads as three units.
 *
 * The row is always the height of a label and two status lines, top aligned,
 * so it never reflows as lines come and go. The counts come from the connect
 * view model's grid points, the same window the connect widget draws, and the
 * category is the SDK's for the provider (`ProviderGridPoint.ipFamily`).
 */
struct IpFamilyStatusRow: View {

    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var connectViewModel: ConnectViewModel

    // the app's general tween, matching the transport bar
    private let tweenDuration: Double = 1.0

    /// the pixel face of the labels, at the smallest size the app sets it
    private let labelFont = Font.custom("PP NeueBit", size: 16).weight(.bold)
    /// the status lines, in the face of the neighboring panels' rows
    private let statusFont = Font.system(size: 11, weight: .medium).monospacedDigit()

    var body: some View {
        let statuses = ipFamilyColumnStatuses(connectViewModel.gridPoints)
        let tiers = ipFamilyColumnTiers(statuses)

        ZStack(alignment: .topLeading) {

            // the tallest column a status can produce, hidden, so the row keeps
            // the height of a label and two status lines whatever the live
            // columns show (mmm/DESIGNSTYLE.md "Placeholders, not pop-in")
            column(
                label: Text(verbatim: "Dualstack"),
                lines: [.connected(0), .connecting(0)],
                color: .clear
            )
            .hidden()
            .accessibilityHidden(true)

            HStack(alignment: .top, spacing: 8) {
                ForEach(statuses) { status in
                    column(
                        label: label(status.column),
                        lines: ipFamilyStatusLines(status),
                        color: color(tiers[status.column] ?? .unavailable)
                    )
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .animation(.easeInOut(duration: tweenDuration), value: statuses)

        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(statuses))
    }

    /// One column: the label over its status lines, all in the tier's color.
    /// A line fades in and out in place; a count rolls to its new value.
    private func column(label: Text, lines: [IpFamilyStatusLine], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            label
                .font(labelFont)
                .foregroundColor(color)
            ForEach(lines) { line in
                lineText(line)
                    .font(statusFont)
                    .foregroundColor(color)
                    .contentTransition(.numericText())
                    .transition(.opacity)
            }
        }
    }

    private func label(_ column: IpFamilyColumn) -> Text {
        switch column {
        case .dualstack:
            return Text("Dualstack")
        case .v4:
            return Text("IPv4")
        case .v6:
            return Text("IPv6")
        }
    }

    private func lineText(_ line: IpFamilyStatusLine) -> Text {
        switch line {
        case .connected(let count):
            return Text("\(count) connected")
        case .connecting(let count):
            return Text("\(count) connecting")
        case .disconnected:
            return Text("disconnected")
        }
    }

    private func color(_ tier: IpFamilyTier) -> Color {
        let theme = themeManager.currentTheme
        switch tier {
        case .best:
            return theme.textColor
        case .active:
            return theme.textMutedColor
        case .unavailable:
            return theme.textFaintColor
        }
    }

    private func accessibilityLabel(_ statuses: [IpFamilyColumnStatus]) -> String {
        statuses.map { status in
            let lines = ipFamilyStatusLines(status).map { line -> String in
                switch line {
                case .connected(let count):
                    return String(localized: "\(count) connected")
                case .connecting(let count):
                    return String(localized: "\(count) connecting")
                case .disconnected:
                    return String(localized: "disconnected")
                }
            }
            return "\(columnName(status.column)): \(lines.joined(separator: ", "))"
        }.joined(separator: ". ")
    }

    private func columnName(_ column: IpFamilyColumn) -> String {
        switch column {
        case .dualstack:
            return String(localized: "Dualstack")
        case .v4:
            return String(localized: "IPv4")
        case .v6:
            return String(localized: "IPv6")
        }
    }
}

// MARK: - columns
//
// Free functions and plain values rather than view state so the counting, the
// ranking and the line selection are exercised directly by the unit tests.

/// The three columns, in display order, which is also rank order.
enum IpFamilyColumn: String, CaseIterable, Identifiable {
    case dualstack
    case v4
    case v6

    var id: String { rawValue }

    /// The column a provider category lands in. Legacy and unknown categories
    /// read as v4-only, which is what they carry.
    static func of(ipFamily: String) -> IpFamilyColumn {
        switch ipFamily {
        case SdkIpFamilyDualstack:
            return .dualstack
        case SdkIpFamilyV6Only:
            return .v6
        default:
            return .v4
        }
    }

    /// The family's rank, lower is better: dualstack carries both families,
    /// and IPv4 and IPv6 tie below it.
    var rank: Int {
        switch self {
        case .dualstack:
            return 0
        case .v4, .v6:
            return 1
        }
    }
}

/// The emphasis of a column.
enum IpFamilyTier: Equatable {
    /// the best-ranked column with a connected provider, shared on a tie
    case best
    /// something connected or connecting, but a better column is connected
    case active
    /// nothing connected or connecting
    case unavailable
}

/// One status line of a column, in display order: connected, then connecting,
/// or disconnected alone. The id is the kind, so a count change updates a line
/// in place while a line appearing or vanishing is an insertion or removal.
enum IpFamilyStatusLine: Identifiable, Equatable {
    case connected(Int)
    case connecting(Int)
    case disconnected

    var id: String {
        switch self {
        case .connected:
            return "connected"
        case .connecting:
            return "connecting"
        case .disconnected:
            return "disconnected"
        }
    }
}

/// One provider as the row sees it: its grid state and its family category.
struct IpFamilyStatusPoint {
    let state: String
    let ipFamily: String

    init(state: String, ipFamily: String) {
        self.state = state
        self.ipFamily = ipFamily
    }

    init(point: SdkProviderGridPoint) {
        self.init(state: point.state, ipFamily: point.ipFamily)
    }
}

struct IpFamilyColumnStatus: Identifiable, Equatable {
    let column: IpFamilyColumn
    /// the Added providers in this category
    let connectedCount: Int
    /// the InEvaluation providers in this category
    let connectingCount: Int

    var id: String { column.id }

    /// nothing connected or connecting: the column reads "disconnected"
    var isUnavailable: Bool {
        connectedCount == 0 && connectingCount == 0
    }
}

/// the grid state of a routing-eligible provider, as the SDK spells it
private let ipFamilyConnectedState = "Added"
/// the grid state of a provider still being evaluated, as the SDK spells it
private let ipFamilyConnectingState = "InEvaluation"

/// The three columns, always present, counting only the connected and the
/// connecting providers of each category.
func ipFamilyColumnStatuses(_ points: [IpFamilyStatusPoint]) -> [IpFamilyColumnStatus] {
    var connectedCounts: [IpFamilyColumn: Int] = [:]
    var connectingCounts: [IpFamilyColumn: Int] = [:]
    for point in points {
        let column = IpFamilyColumn.of(ipFamily: point.ipFamily)
        switch point.state {
        case ipFamilyConnectedState:
            connectedCounts[column, default: 0] += 1
        case ipFamilyConnectingState:
            connectingCounts[column, default: 0] += 1
        default:
            break
        }
    }
    return IpFamilyColumn.allCases.map { column in
        IpFamilyColumnStatus(
            column: column,
            connectedCount: connectedCounts[column] ?? 0,
            connectingCount: connectingCounts[column] ?? 0
        )
    }
}

func ipFamilyColumnStatuses(_ gridPoints: [SdkId: SdkProviderGridPoint]) -> [IpFamilyColumnStatus] {
    ipFamilyColumnStatuses(gridPoints.values.map { IpFamilyStatusPoint(point: $0) })
}

/// The tier of every column: the best rank among the columns with a connected
/// provider is bright (every column at that rank, on a tie), any other column
/// with a live provider is active, and the rest are unavailable. A column that
/// is only connecting carries no traffic yet, so it is never best.
func ipFamilyColumnTiers(_ statuses: [IpFamilyColumnStatus]) -> [IpFamilyColumn: IpFamilyTier] {
    let bestRank = statuses
        .filter { 0 < $0.connectedCount }
        .map { $0.column.rank }
        .min()
    var tiers: [IpFamilyColumn: IpFamilyTier] = [:]
    for status in statuses {
        if status.isUnavailable {
            tiers[status.column] = .unavailable
        } else if 0 < status.connectedCount && status.column.rank == bestRank {
            tiers[status.column] = .best
        } else {
            tiers[status.column] = .active
        }
    }
    return tiers
}

/// The status lines of a column: the non-zero counts, connected first, or
/// "disconnected" alone when both are zero.
func ipFamilyStatusLines(_ status: IpFamilyColumnStatus) -> [IpFamilyStatusLine] {
    var lines: [IpFamilyStatusLine] = []
    if 0 < status.connectedCount {
        lines.append(.connected(status.connectedCount))
    }
    if 0 < status.connectingCount {
        lines.append(.connecting(status.connectingCount))
    }
    if lines.isEmpty {
        lines.append(.disconnected)
    }
    return lines
}
