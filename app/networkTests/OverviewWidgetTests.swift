//
//  OverviewWidgetTests.swift
//  networkTests
//
//  The overview widget (apple/DUO.md, "Samsung cover screen (item 16)",
//  option A): its layout at the large size and wide at extra large; what its
//  globe and tiles show connected, disconnected and signed out; today's
//  traffic by local hour, kept across a tunnel restart and started over at
//  midnight; the contract circles that fit a tile; and the sparkline's
//  bars. The same cases as Android's OverviewWidgetTest, so the two widgets
//  agree. The SwiftUI drawing itself needs WidgetKit; its rules are here.
//

import Foundation
import Testing
@testable import URnetwork

struct OverviewWidgetTests {

    private static let mib: Int64 = 1024 * 1024
    private static let gib: Int64 = 1024 * mib

    private static func calendar(_ timeZone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone)!
        return calendar
    }

    private static let utc = calendar("UTC")
    private static let berlin = calendar("Europe/Berlin")

    private static func date(_ calendar: Calendar, _ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private static let now = date(utc, 2026, 10, 28, 15, 30)

    private static let providers = [
        WidgetProviderSnapshot(
            id: "p1", country: "Germany", countryCode: "de", region: "Berlin", city: "Berlin",
            lat: 52.52, lon: 13.40, connectedSinceMillis: 0, colorHex: "663F46"
        ),
        WidgetProviderSnapshot(
            id: "p2", country: "Japan", countryCode: "jp", region: "Tokyo", city: "Tokyo",
            lat: 35.68, lon: 139.69, connectedSinceMillis: 0, colorHex: "F94144"
        ),
    ]

    private static func contract(_ id: String) -> WidgetContractSnapshot {
        WidgetContractSnapshot(id: id, usedByteCount: 1, totalByteCount: 2, bitRate: 0, hasStream: false)
    }

    private static let peers = [
        WidgetContractPeerSnapshot(
            id: "a", send: [contract("s1"), contract("s2")], receive: [contract("r1")],
            sendByteCount: 3 * mib, receiveByteCount: 1 * mib, lastActivityMillis: 0
        ),
        WidgetContractPeerSnapshot(
            id: "b", send: [contract("s3")], receive: [],
            sendByteCount: 2 * mib, receiveByteCount: 0, lastActivityMillis: 0
        ),
    ]

    /// 10 MiB in the day's first hour and 32 MiB in its third.
    private static let today = WidgetTodaySnapshot(
        dayStart: utc.startOfDay(for: now), hourlyByteCounts: [10 * mib, 0, 32 * mib]
    )

    private static let balance = WidgetBalanceSnapshot(
        updatedAt: now,
        startBalanceByteCount: 5 * gib,
        balanceByteCount: 4 * gib,
        openTransferByteCount: 0,
        isPro: false
    )

    /// Connected with the tunnel up, unless a test says otherwise.
    private static func overview(
        showsTunnelData: Bool = true,
        balance: WidgetBalanceSnapshot? = balance,
        today: WidgetTodaySnapshot? = today
    ) -> WidgetOverview {
        WidgetOverview(
            tunnel: WidgetTunnelSnapshot(
                updatedAt: now, tunnelActive: true, providing: false,
                location: nil, providers: providers,
                throughput: WidgetThroughputSnapshot(bucketSeconds: 1, buckets: [], today: today),
                contracts: peers
            ),
            balance: balance,
            showsTunnelData: showsTunnelData,
            now: now,
            calendar: utc
        )
    }

    // MARK: Layout

    /// The tiles a third of the width, the globe four fifths of the shorter
    /// side, a fifth past the left edge and a tenth past the bottom.
    @Test func theLayoutIsTheMockupsAtTheCoversSize() {
        let layout = WidgetOverviewLayout(width: 352, height: 339, wide: false)
        #expect(abs(layout.tileWidth - 120) < 0.01)
        #expect(abs(layout.globeDiameter - 271.2) < 0.01)
        #expect(abs(layout.globeLeft - -54.24) < 0.01)
        #expect(abs(layout.globeTop - 94.92) < 0.01)
        #expect(!layout.wideTiles)
    }

    /// Whatever the size, the globe bleeds off the bottom left corner, and
    /// the tiles stay within bounds.
    @Test func theLayoutGrowsWithTheWidget() {
        let large = WidgetOverviewLayout(width: 600, height: 600, wide: false)
        #expect(large.tileWidth == 200)
        #expect(large.globeDiameter == 480)
        // the large sizes of the smallest and the largest iPhones
        for (width, height) in [(292.0, 311.0), (338.0, 354.0), (364.0, 382.0), (600.0, 600.0)] {
            let layout = WidgetOverviewLayout(width: width, height: height, wide: false)
            #expect(layout.globeLeft < 0)
            #expect(height < layout.globeTop + layout.globeDiameter)
            #expect(120 <= layout.tileWidth && layout.tileWidth <= 200)
        }
    }

    /// Extra large is about twice as wide as tall: the globe grows with the
    /// height so it stays below the header, and the tiles take the width it
    /// leaves, beside it rather than over it.
    @Test func extraLargeLaysTheTilesOutWide() {
        // iPad mini, iPad 11-inch, iPad 13-inch
        for (width, height) in [(634.5, 305.5), (715.5, 342.0), (795.0, 378.5)] {
            let layout = WidgetOverviewLayout(width: width, height: height, wide: true)
            #expect(layout.wideTiles)
            #expect(layout.globeLeft < 0)
            #expect(height < layout.globeTop + layout.globeDiameter)
            // below a header of about 60 pt
            #expect(60 < layout.globeTop)
            // the tiles, inside a 16 pt margin, start right of the globe
            #expect(layout.globeLeft + layout.globeDiameter < width - 16 - layout.tileWidth)
        }
    }

    // MARK: What shows

    @Test func connectedTheGlobeAndTheTilesShowTheTunnel() throws {
        let overview = Self.overview()
        #expect(!overview.dimmed)
        #expect(overview.providers == Self.providers)
        #expect(overview.balance == "4.00 GiB")
        #expect(overview.traffic == "42.0 MiB")
        #expect(overview.trafficHours == [10 * Self.mib, 0, 32 * Self.mib])
        // every peer's contracts in one send stack and one receive stack,
        // most relevant peer first
        #expect(overview.contracts == "4")
        #expect(try #require(overview.send).map(\.id) == ["s1", "s2", "s3"])
        #expect(try #require(overview.receive).map(\.id) == ["r1"])
        #expect(overview.sendByteCount == 5 * Self.mib)
        #expect(overview.receiveByteCount == 1 * Self.mib)
    }

    @Test func disconnectedTheGlobeDimsAndTrafficAndContractsReadADash() {
        let disconnected = Self.overview(showsTunnelData: false)
        let signedOut = Self.overview(showsTunnelData: false, balance: nil)
        for overview in [disconnected, signedOut] {
            #expect(overview.dimmed)
            #expect(overview.providers.isEmpty)
            #expect(overview.traffic == "—")
            #expect(overview.trafficHours == nil)
            #expect(overview.contracts == "—")
            #expect(overview.send == nil)
            #expect(overview.receive == nil)
        }
        // the balance stays; signed out there is none
        #expect(disconnected.balance == "4.00 GiB")
        #expect(signedOut.balance == "—")
    }

    @Test func anEarlierDaysTrafficIsNoneToday() {
        let yesterday = WidgetTodaySnapshot(
            dayStart: Self.utc.startOfDay(for: Self.now.addingTimeInterval(-86_400)),
            hourlyByteCounts: [5 * Self.mib]
        )
        let overview = Self.overview(today: yesterday)
        #expect(overview.traffic == "0 B")
        #expect(overview.trafficHours == [])
        // nor is a tunnel that has counted nothing yet
        #expect(Self.overview(today: nil).traffic == "0 B")
    }

    // MARK: Today

    @Test func todayCountsThisDevicesTrafficByLocalHour() throws {
        let nine = Self.date(Self.berlin, 2026, 10, 28, 9, 15)
        var accumulator = WidgetThroughputAccumulator()
        // the first reading is a baseline
        accumulator.recordClient(egress: 100, ingress: 1_000, egressPackets: 1, ingressPackets: 1, at: nine, calendar: Self.berlin)
        accumulator.recordClient(egress: 300, ingress: 5_000, egressPackets: 2, ingressPackets: 2, at: nine.addingTimeInterval(60), calendar: Self.berlin)
        accumulator.recordClient(egress: 400, ingress: 9_000, egressPackets: 3, ingressPackets: 3, at: nine.addingTimeInterval(3_600), calendar: Self.berlin)
        // traffic relayed while providing is not this device's
        accumulator.recordProvider(egress: 1, ingress: 1, egressPackets: 1, ingressPackets: 1, at: nine)
        accumulator.recordProvider(egress: 1_000_000, ingress: 1_000_000, egressPackets: 9, ingressPackets: 9, at: nine.addingTimeInterval(3_700))

        let today = try #require(accumulator.today)
        #expect(today.dayStart == Self.berlin.startOfDay(for: nine))
        #expect(today.hourlyByteCounts == Array(repeating: 0, count: 9) + [4_200, 4_100])
        #expect(today.byteCount == 8_300)
        // and the snapshot the extension writes carries it
        #expect(accumulator.snapshot.today == today)
    }

    @Test func aNewDayStartsOverAndAResumeKeepsTheDay() throws {
        let lateEvening = Self.date(Self.berlin, 2026, 10, 28, 23, 30)
        var accumulator = WidgetThroughputAccumulator()
        accumulator.recordClient(egress: 0, ingress: 0, egressPackets: 0, ingressPackets: 0, at: lateEvening, calendar: Self.berlin)
        accumulator.recordClient(egress: 0, ingress: 700, egressPackets: 0, ingressPackets: 1, at: lateEvening.addingTimeInterval(60), calendar: Self.berlin)
        #expect(try #require(accumulator.today).hourlyByteCounts[23] == 700)

        // a restart resumes the day from the snapshot, and its first reading
        // is a new baseline
        var resumed = WidgetThroughputAccumulator(resuming: accumulator.snapshot)
        resumed.recordClient(egress: 0, ingress: 1_000, egressPackets: 0, ingressPackets: 1, at: lateEvening.addingTimeInterval(120), calendar: Self.berlin)
        resumed.recordClient(egress: 0, ingress: 1_300, egressPackets: 0, ingressPackets: 2, at: lateEvening.addingTimeInterval(180), calendar: Self.berlin)
        #expect(try #require(resumed.today).byteCount == 1_000)

        // past midnight it starts over
        let afterMidnight = lateEvening.addingTimeInterval(40 * 60)
        resumed.recordClient(egress: 0, ingress: 1_350, egressPackets: 0, ingressPackets: 3, at: afterMidnight, calendar: Self.berlin)
        let today = try #require(resumed.today)
        #expect(today.dayStart == Self.berlin.startOfDay(for: afterMidnight))
        #expect(today.hourlyByteCounts == [50])
        // and yesterday's reads as nothing today
        #expect(try #require(accumulator.today).asOf(afterMidnight, calendar: Self.berlin).byteCount == 0)
    }

    /// A tunnel snapshot written before the day was counted still decodes,
    /// with nothing counted.
    @Test func anOlderSnapshotStillDecodes() throws {
        let json = #"{"bucketSeconds":1,"buckets":[]}"#
        let snapshot = try WidgetSnapshotStore.decoder.decode(WidgetThroughputSnapshot.self, from: Data(json.utf8))
        #expect(snapshot.today == nil)
        #expect(WidgetThroughputAccumulator(resuming: snapshot).today == nil)
    }

    // MARK: Pictures

    @Test func theContractCirclesThatFitATile() {
        // the large tile's inside: 120 less 9 pt each side
        #expect(ContractStackRow.capacity(width: 102, compact: true) == 5)
        // the extra large tile's picture has room for a long row of the
        // Contracts widget's full-size circles
        #expect(12 <= ContractStackRow.capacity(width: 280, compact: false))
        // one at least, however narrow: the count says the rest
        #expect(ContractStackRow.capacity(width: 1, compact: true) == 1)
    }

    @Test func theSparklineScalesEachHourToTheBusiest() {
        let fractions = WidgetOverview.sparklineFractions([0, 50, 100, 1], slots: 6)
        #expect(fractions.count == 6)
        #expect(fractions[0] == 0)
        #expect(abs(fractions[1] - 0.5) < 0.001)
        #expect(fractions[2] == 1)
        // a little traffic still shows
        #expect(fractions[3] == WidgetOverview.sparklineMinimumFraction)
        // the hours still ahead are empty
        #expect(fractions[4] == 0)
        #expect(fractions[5] == 0)
        // a day with no traffic draws nothing
        #expect(WidgetOverview.sparklineFractions([]).allSatisfy { $0 == 0 })
        #expect(WidgetOverview.sparklineFractions([]).count == WidgetOverview.sparklineSlots)
    }
}
