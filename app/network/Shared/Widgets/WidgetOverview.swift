//
//  WidgetOverview.swift
//  URnetwork
//
//  What the overview widget shows, and where (apple/DUO.md, "Samsung cover
//  screen (item 16)", option A): the dashboard, the provider globe and the
//  contracts in one widget. The rules are values so they are tested
//  (OverviewWidgetTests); the widget target draws them (OverviewWidget.swift).
//  Android's overview and overviewLayout, term for term, except that the
//  extra large family lays its tiles out wide.
//
//  Compiled into the app and the widget extension. No SDK import.
//

import CoreGraphics
import Foundation

/// What the overview shows of an entry. The balance stays whatever the
/// tunnel does (a dash without one); while the tunnel data is hidden (signed
/// out, disconnected) the globe dims with no providers, and traffic and
/// contracts read a dash and draw nothing.
struct WidgetOverview: Equatable {

    /// A tile's figure while it has none to show.
    static let none = "—"

    /// The globe's providers, in the stats' green.
    var providers: [WidgetProviderSnapshot]
    var dimmed: Bool
    var balance: String
    var traffic: String
    /// Today's bytes by local hour, for the sparkline; nil while hidden.
    var trafficHours: [Int64]?
    var contracts: String
    /// Every peer's send stack in one, then every peer's receive stack, most
    /// relevant peer first; nil while hidden.
    var send: [WidgetContractSnapshot]?
    var receive: [WidgetContractSnapshot]?
    var sendByteCount: Int64 = 0
    var receiveByteCount: Int64 = 0

    init(
        tunnel: WidgetTunnelSnapshot,
        balance: WidgetBalanceSnapshot?,
        showsTunnelData: Bool,
        now: Date,
        calendar: Calendar = .current
    ) {
        self.balance = balance.map { formatByteCountCompact($0.balanceByteCount) } ?? Self.none
        guard showsTunnelData else {
            providers = []
            dimmed = true
            traffic = Self.none
            trafficHours = nil
            contracts = Self.none
            send = nil
            receive = nil
            return
        }
        // nothing counted yet, or only on an earlier day, is nothing today
        let today = tunnel.throughput.today?.asOf(now, calendar: calendar)
        let peers = tunnel.contractPeers
        let send = peers.flatMap(\.send)
        let receive = peers.flatMap(\.receive)
        providers = tunnel.providers
        dimmed = false
        traffic = formatByteCountCompact(today?.byteCount ?? 0)
        trafficHours = today?.hourlyByteCounts ?? []
        contracts = "\(send.count + receive.count)"
        self.send = send
        self.receive = receive
        sendByteCount = peers.reduce(0) { $0 + $1.sendByteCount }
        receiveByteCount = peers.reduce(0) { $0 + $1.receiveByteCount }
    }

    // MARK: Sparkline

    /// The sparkline's bars: one per hour of the day.
    static let sparklineSlots = 24
    /// A bar for a little traffic still shows: this share of the plot at least.
    static let sparklineMinimumFraction = 0.08

    /// Each slot's bar height, 0 to 1 of the plot: its value against the
    /// largest, at least `sparklineMinimumFraction` above 0. The hours still
    /// ahead are 0.
    static func sparklineFractions(_ values: [Int64], slots: Int = sparklineSlots) -> [Double] {
        let largest = values.max() ?? 0
        return (0..<slots).map { slot in
            let value = slot < values.count ? values[slot] : 0
            guard 0 < value, 0 < largest else {
                return 0
            }
            return max(sparklineMinimumFraction, Double(value) / Double(largest))
        }
    }
}

/// Where the overview's parts go in a widget `width` x `height`: the tiles'
/// width, and the globe's diameter and its top left corner, past the
/// widget's left edge, so the globe bleeds off the bottom left corner and
/// stays clear of the header.
struct WidgetOverviewLayout: Equatable {

    var tileWidth: CGFloat
    var globeDiameter: CGFloat
    var globeLeft: CGFloat
    var globeTop: CGFloat
    /// Each tile's figure beside its picture rather than above it.
    var wideTiles: Bool

    /// Large, near square, from the mockup at the cover's 352 x 339: the
    /// tiles a third of the width, within bounds; the globe four fifths of
    /// the shorter side, a fifth of it past the left edge and a tenth past
    /// the bottom.
    private static let tileWidthShare: CGFloat = 0.34
    private static let tileMinimumWidth: CGFloat = 120
    private static let tileMaximumWidth: CGFloat = 200
    private static let globeShare: CGFloat = 0.8
    private static let globePastLeft: CGFloat = 0.2
    private static let globePastBottom: CGFloat = 0.1

    /// Extra large, about twice as wide as tall: the globe can grow only
    /// with the height, or it reaches the header, so the tiles take the
    /// width it leaves and lay out wide.
    private static let wideTileWidthShare: CGFloat = 0.58
    private static let wideGlobeShare: CGFloat = 0.9
    private static let wideGlobePastLeft: CGFloat = 0.15
    private static let wideGlobePastBottom: CGFloat = 0.12

    init(width: CGFloat, height: CGFloat, wide: Bool) {
        if wide {
            globeDiameter = Self.wideGlobeShare * height
            tileWidth = Self.wideTileWidthShare * width
            globeLeft = -Self.wideGlobePastLeft * globeDiameter
            globeTop = height - (1 - Self.wideGlobePastBottom) * globeDiameter
        } else {
            globeDiameter = Self.globeShare * min(width, height)
            tileWidth = min(max(Self.tileWidthShare * width, Self.tileMinimumWidth), Self.tileMaximumWidth)
            globeLeft = -Self.globePastLeft * globeDiameter
            globeTop = height - (1 - Self.globePastBottom) * globeDiameter
        }
        wideTiles = wide
    }
}
