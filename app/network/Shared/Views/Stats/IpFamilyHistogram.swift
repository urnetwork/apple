//
//  IpFamilyHistogram.swift
//  URnetwork
//

import SwiftUI
import URnetworkSdk

/**
 * The address families of the connected providers, as three wrapping rows of
 * dots under the transport bar: providers proven on both families, on IPv4
 * only, and on IPv6 only (connect/IPV6.md D2).
 *
 * One dot per ADDED provider in the window, the same diameter as the connect
 * widget's live cell (the 256pt canvas over the grid width) and the same green,
 * so a dot on the widget and a dot here read as the same provider. Rows wrap
 * on narrow drawers with the transport bar's FlowRow. A row with no providers
 * shows just its label, so the three rows are always present and the card
 * never reflows as providers move between categories.
 *
 * The rows come from the connect view model's grid points, which is the same
 * window the widget draws; the family is the SDK's category for the provider
 * (`ProviderGridPoint.ipFamily`).
 */
struct IpFamilyHistogram: View {

    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var connectViewModel: ConnectViewModel

    // the app's general tween, matching the transport bar
    private let tweenDuration: Double = 1.0

    var body: some View {
        let rows = ipFamilyHistogramRows(connectViewModel.gridPoints)
        let dotSize = ipFamilyHistogramDotSize(gridWidth: connectViewModel.gridWidth)
        let theme = themeManager.currentTheme

        VStack(alignment: .leading, spacing: 6) {

            Text("IP versions")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.textMutedColor)

            ForEach(rows) { row in
                HStack(alignment: .top, spacing: 8) {
                    rowLabel(row.family)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.textMutedColor)
                        .frame(width: 32, alignment: .leading)
                        // keep the label centered on the first dot row
                        .frame(minHeight: dotSize)

                    FlowRow(horizontalSpacing: 2, verticalSpacing: 2) {
                        ForEach(row.pointIds, id: \.self) { _ in
                            Circle()
                                .fill(Color.urGreen)
                                .frame(width: dotSize, height: dotSize)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .animation(.easeInOut(duration: tweenDuration), value: row.pointIds)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(rows))
    }

    @ViewBuilder
    private func rowLabel(_ family: IpFamilyHistogramFamily) -> some View {
        switch family {
        case .both:
            Text("Both")
        case .v4:
            Text("v4")
        case .v6:
            Text("v6")
        }
    }

    private func accessibilityLabel(_ rows: [IpFamilyHistogramRow]) -> String {
        rows.map { row in
            let name: String
            switch row.family {
            case .both:
                name = String(localized: "IPv4 and IPv6")
            case .v4:
                name = String(localized: "IPv4")
            case .v6:
                name = String(localized: "IPv6")
            }
            return "\(name): \(row.pointIds.count)"
        }.joined(separator: ", ")
    }
}

// MARK: - rows
//
// Free functions and plain values rather than view state so the grouping and
// the dot size are exercised directly by the unit tests.

/// The three histogram rows, in display order.
enum IpFamilyHistogramFamily: String, CaseIterable, Identifiable {
    case both
    case v4
    case v6

    var id: String { rawValue }

    /// The row a provider category lands in. Legacy and unknown categories read
    /// as v4-only, which is what they carry.
    static func of(ipFamily: String) -> IpFamilyHistogramFamily {
        switch ipFamily {
        case SdkIpFamilyDualstack:
            return .both
        case SdkIpFamilyV6Only:
            return .v6
        default:
            return .v4
        }
    }
}

/// One provider as the histogram sees it: its id (for a stable dot order and
/// the insertion animation), its grid state, and its family category.
struct IpFamilyHistogramPoint {
    let id: String
    let state: String
    let ipFamily: String

    init(id: String, state: String, ipFamily: String) {
        self.id = id
        self.state = state
        self.ipFamily = ipFamily
    }

    init(id: SdkId, point: SdkProviderGridPoint) {
        self.init(id: id.idStr, state: point.state, ipFamily: point.ipFamily)
    }
}

struct IpFamilyHistogramRow: Identifiable, Equatable {
    let family: IpFamilyHistogramFamily
    /// the ADDED providers in this family, in a stable order
    let pointIds: [String]

    var id: String { family.id }
}

/// the grid state of a routing-eligible provider, as the SDK spells it
private let ipFamilyHistogramAddedState = "Added"

/// The three rows, always present, holding only the ADDED providers. Dots are
/// ordered by provider id so a row does not shuffle on every grid notification.
func ipFamilyHistogramRows(_ points: [IpFamilyHistogramPoint]) -> [IpFamilyHistogramRow] {
    var idsByFamily: [IpFamilyHistogramFamily: [String]] = [:]
    for point in points where point.state == ipFamilyHistogramAddedState {
        idsByFamily[IpFamilyHistogramFamily.of(ipFamily: point.ipFamily), default: []].append(point.id)
    }
    return IpFamilyHistogramFamily.allCases.map { family in
        IpFamilyHistogramRow(family: family, pointIds: (idsByFamily[family] ?? []).sorted())
    }
}

func ipFamilyHistogramRows(_ gridPoints: [SdkId: SdkProviderGridPoint]) -> [IpFamilyHistogramRow] {
    ipFamilyHistogramRows(gridPoints.map { IpFamilyHistogramPoint(id: $0.key, point: $0.value) })
}

/// the connect widget's canvas width, which the widget divides by the grid
/// width to size a point (ConnectCanvasConnectingStateView.ViewModel)
let ipFamilyHistogramCanvasWidth: CGFloat = 256

/// the grid width the widget is sized for before the SDK reports one
let ipFamilyHistogramDefaultGridWidth: Int32 = 16

/// The dot diameter: the connect widget's live cell, so a provider is the same
/// size here as on the widget. Falls back to the widget's default grid while
/// the grid has no width (no points yet).
func ipFamilyHistogramDotSize(gridWidth: Int32) -> CGFloat {
    let width = 0 < gridWidth ? gridWidth : ipFamilyHistogramDefaultGridWidth
    return ipFamilyHistogramCanvasWidth / CGFloat(width)
}
