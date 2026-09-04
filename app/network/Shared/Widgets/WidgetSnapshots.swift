//
//  WidgetSnapshots.swift
//  URnetwork
//
//  What the Home Screen widgets render, and where it comes from.
//
//  Widgets cannot run the Go SDK (a ~30 MB process budget, no long-lived
//  process) and are only rendered from a timeline, so they read a snapshot
//  that the processes holding the data write into the App Group container:
//
//    - the packet tunnel extension owns the tunnel: the connected location,
//      the connected providers (with coordinates for the globe) and the
//      cumulative packet counters it folds into one-minute throughput buckets
//    - the app owns the account: the transfer balance, which is an API call
//      the extension also makes on a slow cadence while the tunnel is up
//
//  Reads and writes are whole-file and atomic; the newest `updatedAt` wins.
//  Compiled into the app, the packet tunnel extension and the widget
//  extension. No SDK import, on purpose.
//

import Foundation

/// WidgetKit "kind" identifiers. Kept here (not in WidgetKit-importing code)
/// so every process can address a widget for a reload.
enum WidgetKinds {
    static let quickConnectControl = "network.ur.widgets.quickconnect"
    static let dashboard = "network.ur.widgets.dashboard"
    static let providerGlobe = "network.ur.widgets.globe"
    static let contracts = "network.ur.widgets.contracts"
}

/// One open contract, un-aggregated (contracts are never paired: a peer's
/// send and receive contracts are many-to-many, as in the app's contract
/// details view).
struct WidgetContractSnapshot: Codable, Equatable, Identifiable {
    var id: String
    var usedByteCount: Int64
    var totalByteCount: Int64
    var bitRate: Int64
    /// The contract's transfer path carries a stream id: drawn as a double
    /// ring, as in the app.
    var hasStream: Bool

    var isActive: Bool { 0 < bitRate }
}

/// One peer's open client contracts as two independent stacks, newest
/// first, mirroring the SDK's ContractPeerRow.
struct WidgetContractPeerSnapshot: Codable, Equatable, Identifiable {
    /// The peer's client id.
    var id: String
    /// Contracts sending to the peer, newest first.
    var send: [WidgetContractSnapshot]
    /// Contracts receiving from the peer, newest first.
    var receive: [WidgetContractSnapshot]
    /// Bytes moved to / from the peer across its contracts in the current run.
    var sendByteCount: Int64
    var receiveByteCount: Int64
    /// Unix millis of the peer's last byte movement, 0 if none yet.
    var lastActivityMillis: Int64

    var isActive: Bool {
        send.contains { $0.isActive } || receive.contains { $0.isActive }
    }

    var bitRate: Int64 {
        send.reduce(0) { $0 + $1.bitRate } + receive.reduce(0) { $0 + $1.bitRate }
    }
}

struct WidgetLocationSnapshot: Codable, Equatable {
    var name: String
    var countryCode: String
    var city: String
    var region: String
    var country: String
    var bestAvailable: Bool
    var networkPeer: Bool
    var providerCount: Int
    /// The SDK palette color for this location (six hex digits, no `#`).
    var colorHex: String
}

struct WidgetProviderSnapshot: Codable, Equatable, Identifiable {
    /// The provider's client id.
    var id: String
    var country: String
    var countryCode: String
    var region: String
    var city: String
    /// Plot coordinates (city centroid, else region centroid); nil when the
    /// provider's location is unknown.
    var lat: Double?
    var lon: Double?
    var connectedSinceMillis: Int64
    var colorHex: String

    var plottable: Bool { lat != nil && lon != nil }

    var connectedSince: Date {
        Date(timeIntervalSince1970: TimeInterval(connectedSinceMillis) / 1000)
    }
}

/// One fixed-width bucket of bytes and packets moved, per side.
struct WidgetThroughputBucket: Codable, Equatable {
    /// Bucket start, unix seconds.
    var start: Int64
    /// This device's own traffic through providers (the "remote" route).
    var clientEgress: Int64
    var clientIngress: Int64
    /// Traffic relayed for others while providing (the provider's local and
    /// blocked routes, as the app's provider charts draw them).
    var providerEgress: Int64
    var providerIngress: Int64
    /// Packet counts for the same routes, drawn as the chart's second series
    /// (pink) next to the bytes (green), as the app's TransferChart does.
    /// Absent in snapshots written before packets were recorded: they decode
    /// as zero, which draws as a flat packet line.
    var clientEgressPackets: Int64 = 0
    var clientIngressPackets: Int64 = 0
    var providerEgressPackets: Int64 = 0
    var providerIngressPackets: Int64 = 0

    static func empty(start: Int64) -> WidgetThroughputBucket {
        WidgetThroughputBucket(
            start: start, clientEgress: 0, clientIngress: 0, providerEgress: 0, providerIngress: 0
        )
    }

    init(
        start: Int64,
        clientEgress: Int64, clientIngress: Int64,
        providerEgress: Int64, providerIngress: Int64,
        clientEgressPackets: Int64 = 0, clientIngressPackets: Int64 = 0,
        providerEgressPackets: Int64 = 0, providerIngressPackets: Int64 = 0
    ) {
        self.start = start
        self.clientEgress = clientEgress
        self.clientIngress = clientIngress
        self.providerEgress = providerEgress
        self.providerIngress = providerIngress
        self.clientEgressPackets = clientEgressPackets
        self.clientIngressPackets = clientIngressPackets
        self.providerEgressPackets = providerEgressPackets
        self.providerIngressPackets = providerIngressPackets
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        start = try c.decode(Int64.self, forKey: .start)
        clientEgress = try c.decode(Int64.self, forKey: .clientEgress)
        clientIngress = try c.decode(Int64.self, forKey: .clientIngress)
        providerEgress = try c.decode(Int64.self, forKey: .providerEgress)
        providerIngress = try c.decode(Int64.self, forKey: .providerIngress)
        clientEgressPackets = try c.decodeIfPresent(Int64.self, forKey: .clientEgressPackets) ?? 0
        clientIngressPackets = try c.decodeIfPresent(Int64.self, forKey: .clientIngressPackets) ?? 0
        providerEgressPackets = try c.decodeIfPresent(Int64.self, forKey: .providerEgressPackets) ?? 0
        providerIngressPackets = try c.decodeIfPresent(Int64.self, forKey: .providerIngressPackets) ?? 0
    }
}

struct WidgetThroughputSnapshot: Codable, Equatable {
    var bucketSeconds: Int64
    /// Oldest first. Missing buckets mean no traffic.
    var buckets: [WidgetThroughputBucket]

    static let empty = WidgetThroughputSnapshot(
        bucketSeconds: WidgetThroughputAccumulator.bucketSeconds, buckets: []
    )
}

struct WidgetTunnelSnapshot: Codable, Equatable {
    var version: Int = 1
    var updatedAt: Date
    /// The extension process was alive when this was written. A stale
    /// snapshot with `tunnelActive == true` is possible when the extension was
    /// killed without running its stop path; readers should prefer the live
    /// NEVPNStatus for the on/off question and use this for the rest.
    var tunnelActive: Bool
    var providing: Bool
    /// The provide control mode ("auto", "always", "network", "never"); nil
    /// when unknown or written before this field existed.
    var provideMode: String? = nil
    var location: WidgetLocationSnapshot?
    /// Active providers in the tunnel's window, oldest-connected first.
    var providers: [WidgetProviderSnapshot]
    var throughput: WidgetThroughputSnapshot
    /// This device's open client contracts by peer, most relevant first
    /// (active peers, then most recently active, then most bytes). Optional
    /// so snapshots written before this field existed still decode.
    var contracts: [WidgetContractPeerSnapshot]? = nil

    var contractPeers: [WidgetContractPeerSnapshot] { contracts ?? [] }

    static func inactive(at date: Date = Date()) -> WidgetTunnelSnapshot {
        WidgetTunnelSnapshot(
            updatedAt: date, tunnelActive: false, providing: false,
            location: nil, providers: [], throughput: .empty, contracts: []
        )
    }
}

struct WidgetBalanceSnapshot: Codable, Equatable {
    var version: Int = 1
    var updatedAt: Date
    var startBalanceByteCount: Int64
    var balanceByteCount: Int64
    var openTransferByteCount: Int64
    var isPro: Bool

    /// The three segments the app's usage bar draws.
    var usedByteCount: Int64 {
        max(0, startBalanceByteCount - balanceByteCount - openTransferByteCount)
    }
}

/// Folds cumulative byte and packet counters into fixed one-minute buckets. Pure
/// value type so the extension can persist it inside the snapshot and pick
/// up where it left off after a restart (the chart then survives a tunnel
/// restart instead of resetting to flat).
struct WidgetThroughputAccumulator: Codable, Equatable {

    static let bucketSeconds: Int64 = 60
    /// One hour of history.
    static let bucketCount = 60

    private(set) var buckets: [WidgetThroughputBucket] = []

    private var lastClientEgress: Int64?
    private var lastClientIngress: Int64?
    private var lastProviderEgress: Int64?
    private var lastProviderIngress: Int64?
    private var lastClientEgressPackets: Int64?
    private var lastClientIngressPackets: Int64?
    private var lastProviderEgressPackets: Int64?
    private var lastProviderIngressPackets: Int64?

    init() {}

    init(resuming snapshot: WidgetThroughputSnapshot) {
        if snapshot.bucketSeconds == Self.bucketSeconds {
            buckets = Array(snapshot.buckets.suffix(Self.bucketCount))
        }
    }

    var snapshot: WidgetThroughputSnapshot {
        WidgetThroughputSnapshot(bucketSeconds: Self.bucketSeconds, buckets: buckets)
    }

    /// Record the client-side cumulative counters (bytes and packets) as of `date`.
    mutating func recordClient(
        egress: Int64, ingress: Int64,
        egressPackets: Int64, ingressPackets: Int64,
        at date: Date = Date()
    ) {
        let dEgress = Self.delta(from: lastClientEgress, to: egress)
        let dIngress = Self.delta(from: lastClientIngress, to: ingress)
        let dEgressPackets = Self.delta(from: lastClientEgressPackets, to: egressPackets)
        let dIngressPackets = Self.delta(from: lastClientIngressPackets, to: ingressPackets)
        lastClientEgress = egress
        lastClientIngress = ingress
        lastClientEgressPackets = egressPackets
        lastClientIngressPackets = ingressPackets
        guard 0 < dEgress || 0 < dIngress || 0 < dEgressPackets || 0 < dIngressPackets else { return }
        var bucket = currentBucket(at: date)
        bucket.clientEgress += dEgress
        bucket.clientIngress += dIngress
        bucket.clientEgressPackets += dEgressPackets
        bucket.clientIngressPackets += dIngressPackets
        buckets[buckets.count - 1] = bucket
    }

    /// Record the provider-side cumulative counters (bytes and packets) as of `date`.
    mutating func recordProvider(
        egress: Int64, ingress: Int64,
        egressPackets: Int64, ingressPackets: Int64,
        at date: Date = Date()
    ) {
        let dEgress = Self.delta(from: lastProviderEgress, to: egress)
        let dIngress = Self.delta(from: lastProviderIngress, to: ingress)
        let dEgressPackets = Self.delta(from: lastProviderEgressPackets, to: egressPackets)
        let dIngressPackets = Self.delta(from: lastProviderIngressPackets, to: ingressPackets)
        lastProviderEgress = egress
        lastProviderIngress = ingress
        lastProviderEgressPackets = egressPackets
        lastProviderIngressPackets = ingressPackets
        guard 0 < dEgress || 0 < dIngress || 0 < dEgressPackets || 0 < dIngressPackets else { return }
        var bucket = currentBucket(at: date)
        bucket.providerEgress += dEgress
        bucket.providerIngress += dIngress
        bucket.providerEgressPackets += dEgressPackets
        bucket.providerIngressPackets += dIngressPackets
        buckets[buckets.count - 1] = bucket
    }

    /// A counter that went backwards is a restarted session: count the new
    /// value as the delta rather than dropping it. The first observation
    /// after a resume is a baseline only.
    private static func delta(from last: Int64?, to value: Int64) -> Int64 {
        guard let last else { return 0 }
        return value < last ? value : value - last
    }

    private mutating func currentBucket(at date: Date) -> WidgetThroughputBucket {
        let start = (Int64(date.timeIntervalSince1970) / Self.bucketSeconds) * Self.bucketSeconds
        if let last = buckets.last, last.start == start {
            return last
        }
        // a late sample for an older bucket is folded into the newest bucket
        // rather than reordering history
        if let last = buckets.last, start < last.start {
            return last
        }
        buckets.append(.empty(start: start))
        if Self.bucketCount < buckets.count {
            buckets.removeFirst(buckets.count - Self.bucketCount)
        }
        return buckets[buckets.count - 1]
    }
}

/// The cross-process "a snapshot was published" signal. Posted by whoever
/// writes a snapshot (the tunnel extension, the app) and by every widget
/// reload request, so the app's own view of the widgets (Account > Widgets)
/// re-renders the moment the pinned widgets would. Darwin notifications
/// carry no payload and cross the app / extension boundary; a listener
/// re-reads the snapshot files.
enum WidgetSnapshotChange {

    static let darwinNotificationName = "network.ur.widgets.snapshot-changed"

    static func post() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(darwinNotificationName as CFString),
            nil,
            nil,
            true
        )
    }
}

/// Account > Widgets is on screen: the app marks this while its live previews
/// are visible, so the tunnel extension publishes at a preview cadence (every
/// couple of seconds instead of once a minute) and the previews move like the
/// pinned widgets would. The mark carries an expiry and the app re-arms it
/// while the screen stays up, so an app that dies with the screen open cannot
/// leave the extension writing fast forever. Posted as a Darwin notification,
/// the one channel that crosses from the app to the extension.
enum WidgetPreviewVisibility {

    static let darwinNotificationName = "network.ur.widgets.preview-visibility"
    static let fileName = "preview-visible.json"
    /// How long one mark lasts; the app re-arms every `heartbeatInterval`.
    static let markInterval: TimeInterval = 90
    static let heartbeatInterval: TimeInterval = 30

    private struct Mark: Codable {
        var until: Date
    }

    /// True while an unexpired mark is on disk.
    static var isVisible: Bool {
        guard let url = WidgetSnapshotStore.directoryURL?.appendingPathComponent(fileName),
              let data = try? Data(contentsOf: url),
              let mark = try? WidgetSnapshotStore.decoder.decode(Mark.self, from: data) else {
            return false
        }
        return Date() < mark.until
    }

    /// The previews are showing: mark (or re-arm) and tell the extension.
    static func mark() {
        guard let directory = WidgetSnapshotStore.directoryURL else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try WidgetSnapshotStore.encoder.encode(Mark(until: Date().addingTimeInterval(markInterval)))
            try data.write(to: directory.appendingPathComponent(fileName), options: .atomic)
        } catch {
            return
        }
        post()
    }

    /// The previews are gone: clear the mark and tell the extension.
    static func clear() {
        guard let url = WidgetSnapshotStore.directoryURL?.appendingPathComponent(fileName) else { return }
        try? FileManager.default.removeItem(at: url)
        post()
    }

    private static func post() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(darwinNotificationName as CFString),
            nil, nil, true
        )
    }
}

enum WidgetSnapshotStore {

    static let directoryName = "Widgets"
    static let tunnelFileName = "tunnel.json"
    static let balanceFileName = "balance.json"

    /// The shared directory, or nil when this build has no App Group.
    static var directoryURL: URL? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: DiagnosticsLogContract.appGroupIdentifier
        ) else {
            return nil
        }
        return container.appendingPathComponent(directoryName, isDirectory: true)
    }

    static func loadTunnel() -> WidgetTunnelSnapshot? {
        load(tunnelFileName)
    }

    static func loadBalance() -> WidgetBalanceSnapshot? {
        load(balanceFileName)
    }

    @discardableResult
    static func save(_ snapshot: WidgetTunnelSnapshot) -> Bool {
        save(snapshot, as: tunnelFileName)
    }

    @discardableResult
    static func save(_ snapshot: WidgetBalanceSnapshot) -> Bool {
        save(snapshot, as: balanceFileName)
    }

    /// Removes both snapshots (logout).
    static func clear() {
        guard let directory = directoryURL else {
            return
        }
        for fileName in [tunnelFileName, balanceFileName, WidgetPreviewVisibility.fileName] {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(fileName))
        }
    }

    private static func load<T: Decodable>(_ fileName: String) -> T? {
        guard let url = directoryURL?.appendingPathComponent(fileName),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? decoder.decode(T.self, from: data)
    }

    private static func save<T: Encodable>(_ value: T, as fileName: String) -> Bool {
        guard let directory = directoryURL else {
            return false
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try encoder.encode(value)
            try data.write(to: directory.appendingPathComponent(fileName), options: .atomic)
            WidgetSnapshotChange.post()
            return true
        } catch {
            return false
        }
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
