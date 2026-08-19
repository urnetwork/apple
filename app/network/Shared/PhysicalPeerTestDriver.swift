#if DEBUG

import Foundation

enum PhysicalPageBenchmarkResult {
    private static let logChunkBase64CharacterCount = 720

    static func errorMetrics(
        label: String,
        requestedUrl: String,
        error: String,
        driverCommitMilliseconds: Double?,
        driverFinishMilliseconds: Double
    ) -> [String: Any] {
        let commitValue: Any = driverCommitMilliseconds.map { $0 as Any } ?? NSNull()
        return [
            "label": label,
            "requestedUrl": requestedUrl,
            "error": error,
            "driverCommitMs": commitValue,
            "driverFinishMs": driverFinishMilliseconds,
        ]
    }

    static func jsonString(_ metrics: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(
            withJSONObject: metrics,
            options: [.sortedKeys]
        ) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    // Device console logging has implementation-dependent message limits. A
    // physical result contains enough per-transport counters to exceed those
    // limits, so frame it into independently parseable, ASCII-only records.
    // Base64 also lets us split at a fixed byte boundary without breaking a
    // Unicode scalar inside a benchmark label or navigation error.
    static func logLines(
        json: String,
        recordId: String = UUID().uuidString.lowercased()
    ) -> [String] {
        let payload = Data(json.utf8).base64EncodedString()
        let payloadBytes = Array(payload.utf8)
        let chunkCount = max(
            1,
            (payloadBytes.count + logChunkBase64CharacterCount - 1)
                / logChunkBase64CharacterCount
        )
        var lines: [String] = []
        lines.reserveCapacity(chunkCount)
        for chunkIndex in 0..<chunkCount {
            let start = chunkIndex * logChunkBase64CharacterCount
            let end = min(
                start + logChunkBase64CharacterCount,
                payloadBytes.count
            )
            let chunk = String(
                bytes: payloadBytes[start..<end],
                encoding: .utf8
            ) ?? ""
            lines.append(
                "[PhysicalPageBenchmarkChunk] \(recordId) "
                    + "\(chunkIndex + 1)/\(chunkCount) \(chunk)"
            )
        }
        return lines
    }
}

enum PhysicalPeerTestReadiness {
    static func shouldRestoreConnectionAfterDirect(
        connectionStatus: String?,
        tunnelConnected: Bool
    ) -> Bool {
        tunnelConnected
            || (connectionStatus != nil && connectionStatus != "DISCONNECTED")
    }

    static func benchmarkIsReady(
        connectionStatus: String?,
        tunnelConnected: Bool,
        selectedPeerId: String?,
        expectedPeerId: String?,
        route: PhysicalBenchmarkRoute = .vpn,
        transportMode: String? = nil,
        expectedTransportMode: String? = nil
    ) -> Bool {
        switch route {
        case .direct:
            return connectionStatus == "DISCONNECTED" && !tunnelConnected
        case .vpn:
            guard connectionStatus == "CONNECTED", tunnelConnected else {
                return false
            }
            if let expectedPeerId, !expectedPeerId.isEmpty,
               selectedPeerId != expectedPeerId {
                return false
            }
            if let expectedTransportMode,
               transportMode != expectedTransportMode {
                return false
            }
            return true
        }
    }
}

enum PhysicalBenchmarkRoute: String, Equatable {
    case direct
    case vpn
}

struct PhysicalBenchmarkConfiguration: Equatable {
    static let supportedTransportModes = Set([
        "auto",
        "h3",
        "h1",
        "dns",
        "dnspump",
    ])

    let route: PhysicalBenchmarkRoute
    // Nil preserves the active client policy. A non-nil mode is applied
    // temporarily to the live DeviceRemote and restored after the benchmark;
    // app local-state persistence is deliberately untouched.
    let transportMode: String?

    static func resolve(
        routeValue: String?,
        transportValue: String?,
        expectedPeerId: String?
    ) -> Self? {
        let route: PhysicalBenchmarkRoute
        if let routeValue, !routeValue.isEmpty {
            guard let parsed = PhysicalBenchmarkRoute(rawValue: routeValue) else {
                return nil
            }
            route = parsed
        } else {
            route = .vpn
        }

        let transportMode: String?
        if let transportValue,
           !transportValue.isEmpty,
           transportValue != "current" {
            guard supportedTransportModes.contains(transportValue) else {
                return nil
            }
            transportMode = transportValue
        } else {
            transportMode = nil
        }

        // A Direct sample must prove there is no provider route and has no
        // tunnel carrier to pin. Reject contradictory command lines rather
        // than silently labeling a VPN run as Direct.
        if route == .direct &&
            (transportMode != nil || !(expectedPeerId ?? "").isEmpty) {
            return nil
        }
        return Self(route: route, transportMode: transportMode)
    }
}

struct PhysicalPageBenchmarkRequest: Decodable, Equatable {
    let urlString: String
    let label: String

    private enum CodingKeys: String, CodingKey {
        case urlString = "url"
        case label
    }
}

enum PhysicalPageBenchmarkSuite {
    static func requests(json: String) -> [PhysicalPageBenchmarkRequest]? {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(
                [PhysicalPageBenchmarkRequest].self,
                from: data
              ),
              !decoded.isEmpty else {
            return nil
        }
        for request in decoded {
            guard !request.label.isEmpty,
                  let url = URL(string: request.urlString),
                  let scheme = url.scheme,
                  ["http", "https"].contains(scheme.lowercased()) else {
                return nil
            }
        }
        return decoded
    }
}

#if os(iOS)

import Darwin
import Network
import URnetworkSdk
import UIKit
import WebKit

struct PhysicalPacketCounterTotals: Equatable {
    var remoteEgressPacketCount: Int64 = 0
    var remoteEgressByteCount: Int64 = 0
    var remoteIngressPacketCount: Int64 = 0
    var remoteIngressByteCount: Int64 = 0
    var localEgressPacketCount: Int64 = 0
    var localEgressByteCount: Int64 = 0
    var localIngressPacketCount: Int64 = 0
    var localIngressByteCount: Int64 = 0
    var blockEgressPacketCount: Int64 = 0
    var blockEgressByteCount: Int64 = 0
    var blockIngressPacketCount: Int64 = 0
    var blockIngressByteCount: Int64 = 0

    init() {}

    init(_ stats: SdkPacketStats) {
        remoteEgressPacketCount = stats.remoteEgressPacketCount
        remoteEgressByteCount = stats.remoteEgressByteCount
        remoteIngressPacketCount = stats.remoteIngressPacketCount
        remoteIngressByteCount = stats.remoteIngressByteCount
        localEgressPacketCount = stats.localEgressPacketCount
        localEgressByteCount = stats.localEgressByteCount
        localIngressPacketCount = stats.localIngressPacketCount
        localIngressByteCount = stats.localIngressByteCount
        blockEgressPacketCount = stats.blockEgressPacketCount
        blockEgressByteCount = stats.blockEgressByteCount
        blockIngressPacketCount = stats.blockIngressPacketCount
        blockIngressByteCount = stats.blockIngressByteCount
    }

    func subtracting(_ earlier: Self) -> (value: Self, reset: Bool) {
        var reset = false
        func delta(_ current: Int64, _ previous: Int64) -> Int64 {
            if current < previous {
                reset = true
                return 0
            }
            return current - previous
        }
        var value = Self()
        value.remoteEgressPacketCount = delta(
            remoteEgressPacketCount,
            earlier.remoteEgressPacketCount
        )
        value.remoteEgressByteCount = delta(
            remoteEgressByteCount,
            earlier.remoteEgressByteCount
        )
        value.remoteIngressPacketCount = delta(
            remoteIngressPacketCount,
            earlier.remoteIngressPacketCount
        )
        value.remoteIngressByteCount = delta(
            remoteIngressByteCount,
            earlier.remoteIngressByteCount
        )
        value.localEgressPacketCount = delta(
            localEgressPacketCount,
            earlier.localEgressPacketCount
        )
        value.localEgressByteCount = delta(
            localEgressByteCount,
            earlier.localEgressByteCount
        )
        value.localIngressPacketCount = delta(
            localIngressPacketCount,
            earlier.localIngressPacketCount
        )
        value.localIngressByteCount = delta(
            localIngressByteCount,
            earlier.localIngressByteCount
        )
        value.blockEgressPacketCount = delta(
            blockEgressPacketCount,
            earlier.blockEgressPacketCount
        )
        value.blockEgressByteCount = delta(
            blockEgressByteCount,
            earlier.blockEgressByteCount
        )
        value.blockIngressPacketCount = delta(
            blockIngressPacketCount,
            earlier.blockIngressPacketCount
        )
        value.blockIngressByteCount = delta(
            blockIngressByteCount,
            earlier.blockIngressByteCount
        )
        return (value, reset)
    }

    var jsonObject: [String: Any] {
        [
            "remoteEgressPacketCount": remoteEgressPacketCount,
            "remoteEgressByteCount": remoteEgressByteCount,
            "remoteIngressPacketCount": remoteIngressPacketCount,
            "remoteIngressByteCount": remoteIngressByteCount,
            "localEgressPacketCount": localEgressPacketCount,
            "localEgressByteCount": localEgressByteCount,
            "localIngressPacketCount": localIngressPacketCount,
            "localIngressByteCount": localIngressByteCount,
            "blockEgressPacketCount": blockEgressPacketCount,
            "blockEgressByteCount": blockEgressByteCount,
            "blockIngressPacketCount": blockIngressPacketCount,
            "blockIngressByteCount": blockIngressByteCount,
        ]
    }
}

struct PhysicalPacketStatsSnapshot: Equatable {
    let totals: PhysicalPacketCounterTotals
    let transports: [String: PhysicalPacketCounterTotals]

    init(
        totals: PhysicalPacketCounterTotals,
        transports: [String: PhysicalPacketCounterTotals]
    ) {
        self.totals = totals
        self.transports = transports
    }

    init(_ stats: SdkPacketStats) {
        totals = PhysicalPacketCounterTotals(stats)
        var transports: [String: PhysicalPacketCounterTotals] = [:]
        if let list = stats.transportStats {
            for index in 0..<list.len() {
                guard let item = list.get(index),
                      let itemStats = item.stats else {
                    continue
                }
                transports[item.transportType] = PhysicalPacketCounterTotals(
                    itemStats
                )
            }
        }
        self.transports = transports
    }

    func subtracting(_ earlier: Self) -> PhysicalPacketStatsDelta {
        let totalsDelta = totals.subtracting(earlier.totals)
        var reset = totalsDelta.reset
        var transportDeltas: [String: PhysicalPacketCounterTotals] = [:]
        for transport in Set(transports.keys).union(earlier.transports.keys) {
            let current = transports[transport] ?? PhysicalPacketCounterTotals()
            let previous = earlier.transports[transport]
                ?? PhysicalPacketCounterTotals()
            let transportDelta = current.subtracting(previous)
            reset = reset || transportDelta.reset
            transportDeltas[transport] = transportDelta.value
        }
        return PhysicalPacketStatsDelta(
            totals: totalsDelta.value,
            transports: transportDeltas,
            resetDetected: reset
        )
    }

    var jsonObject: [String: Any] {
        [
            "totals": totals.jsonObject,
            "transports": transports.mapValues(\.jsonObject),
        ]
    }
}

struct PhysicalPacketStatsDelta: Equatable {
    let totals: PhysicalPacketCounterTotals
    let transports: [String: PhysicalPacketCounterTotals]
    let resetDetected: Bool

    var jsonObject: [String: Any] {
        [
            "totals": totals.jsonObject,
            "transports": transports.mapValues(\.jsonObject),
            "counterResetDetected": resetDetected,
        ]
    }
}

private struct PhysicalPathSnapshot: Sendable {
    let status: String
    let expensive: Bool
    let constrained: Bool
    let cellular: Bool
    let wifi: Bool
    let wiredEthernet: Bool
    let supportsIPv4: Bool
    let supportsIPv6: Bool
    let supportsDNS: Bool

    init(_ path: NWPath) {
        switch path.status {
        case .satisfied: status = "satisfied"
        case .requiresConnection: status = "requiresConnection"
        case .unsatisfied: status = "unsatisfied"
        @unknown default: status = "unknown"
        }
        expensive = path.isExpensive
        constrained = path.isConstrained
        cellular = path.usesInterfaceType(.cellular)
        wifi = path.usesInterfaceType(.wifi)
        wiredEthernet = path.usesInterfaceType(.wiredEthernet)
        supportsIPv4 = path.supportsIPv4
        supportsIPv6 = path.supportsIPv6
        supportsDNS = path.supportsDNS
    }

    var jsonObject: [String: Any] {
        [
            "status": status,
            "expensive": expensive,
            "constrained": constrained,
            "cellular": cellular,
            "wifi": wifi,
            "wiredEthernet": wiredEthernet,
            "supportsIPv4": supportsIPv4,
            "supportsIPv6": supportsIPv6,
            "supportsDNS": supportsDNS,
        ]
    }
}

private final class PhysicalPathState: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: PhysicalPathSnapshot?

    func update(_ path: NWPath) {
        lock.lock()
        snapshot = PhysicalPathSnapshot(path)
        lock.unlock()
    }

    func get() -> PhysicalPathSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }
}

private struct PhysicalTelemetrySnapshot {
    let timeUnixMilliseconds: Int64
    let appPhysicalFootprintByteCount: UInt64
    let lowPowerMode: Bool
    let thermalState: String
    let batteryLevel: Float?
    let batteryState: String
    let physicalPath: PhysicalPathSnapshot?
    let packetStats: PhysicalPacketStatsSnapshot?
    let transportSettings: [String: Any]?

    var jsonObject: [String: Any] {
        [
            "timeUnixMs": timeUnixMilliseconds,
            "appPhysicalFootprintBytes": appPhysicalFootprintByteCount,
            "lowPowerMode": lowPowerMode,
            "thermalState": thermalState,
            "batteryLevel": batteryLevel ?? NSNull(),
            "batteryState": batteryState,
            "physicalPath": physicalPath?.jsonObject ?? NSNull(),
            "packetStats": packetStats?.jsonObject ?? NSNull(),
            "transportSettings": transportSettings ?? NSNull(),
        ]
    }
}

@MainActor
private final class PhysicalBenchmarkTelemetry {
    private let device: SdkDeviceRemote
    private let pathState = PhysicalPathState()
    private let pathMonitor = NWPathMonitor(
        prohibitedInterfaceTypes: [.loopback, .other]
    )
    private let pathQueue = DispatchQueue(
        label: "network.ur.physical-test.path"
    )
    private let batteryMonitoringWasEnabled: Bool
    private var closed = false

    init(device: SdkDeviceRemote) {
        self.device = device
        batteryMonitoringWasEnabled = UIDevice.current.isBatteryMonitoringEnabled
        UIDevice.current.isBatteryMonitoringEnabled = true
        let pathState = self.pathState
        pathMonitor.pathUpdateHandler = { path in
            pathState.update(path)
        }
        pathMonitor.start(queue: pathQueue)
        pathState.update(pathMonitor.currentPath)
    }

    func close() {
        guard !closed else { return }
        closed = true
        pathMonitor.cancel()
        UIDevice.current.isBatteryMonitoringEnabled = batteryMonitoringWasEnabled
    }

    func snapshot() -> PhysicalTelemetrySnapshot {
        let processInfo = ProcessInfo.processInfo
        let batteryLevel = UIDevice.current.batteryLevel
        return PhysicalTelemetrySnapshot(
            timeUnixMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000),
            appPhysicalFootprintByteCount: Self.physicalFootprintByteCount(),
            lowPowerMode: processInfo.isLowPowerModeEnabled,
            thermalState: Self.thermalStateName(processInfo.thermalState),
            batteryLevel: batteryLevel >= 0 ? batteryLevel : nil,
            batteryState: Self.batteryStateName(UIDevice.current.batteryState),
            physicalPath: pathState.get(),
            packetStats: device.getPacketStats().map(
                PhysicalPacketStatsSnapshot.init
            ),
            transportSettings: Self.transportSettingsJson(
                device.getTransportSettings()
            )
        )
    }

    func result(since start: PhysicalTelemetrySnapshot) -> [String: Any] {
        let end = snapshot()
        var result: [String: Any] = [
            "start": start.jsonObject,
            "end": end.jsonObject,
        ]
        if let startStats = start.packetStats,
           let endStats = end.packetStats {
            result["packetDelta"] = endStats.subtracting(startStats).jsonObject
        } else {
            result["packetDelta"] = NSNull()
        }
        return result
    }

    private static func transportSettingsJson(
        _ settings: SdkTransportSettings?
    ) -> [String: Any]? {
        guard let settings else { return nil }
        var autoModes: [String] = []
        if let modes = settings.autoModes() {
            autoModes.reserveCapacity(modes.len())
            for index in 0..<modes.len() {
                autoModes.append(modes.get(index))
            }
        }
        return [
            "mode": settings.mode,
            "autoModes": autoModes,
        ]
    }

    private static func thermalStateName(
        _ thermalState: ProcessInfo.ThermalState
    ) -> String {
        switch thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    private static func batteryStateName(
        _ batteryState: UIDevice.BatteryState
    ) -> String {
        switch batteryState {
        case .unknown: return "unknown"
        case .unplugged: return "unplugged"
        case .charging: return "charging"
        case .full: return "full"
        @unknown default: return "unknown"
        }
    }

    private static func physicalFootprintByteCount() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.stride /
                MemoryLayout<natural_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(
                to: integer_t.self,
                capacity: Int(count)
            ) { rebound in
                task_info(
                    mach_task_self_,
                    task_flavor_t(TASK_VM_INFO),
                    rebound,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return info.phys_footprint
    }
}

@MainActor
private final class PhysicalPageBenchmark: NSObject, WKNavigationDelegate {
    private let url: URL
    private let label: String
    private let telemetry: PhysicalBenchmarkTelemetry
    private let configuration: PhysicalBenchmarkConfiguration
    private let routeReadinessMilliseconds: Double
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var start = ContinuousClock.now
    private var commitMilliseconds: Double?
    private var telemetryStart: PhysicalTelemetrySnapshot?

    init(
        url: URL,
        label: String,
        telemetry: PhysicalBenchmarkTelemetry,
        configuration: PhysicalBenchmarkConfiguration,
        routeReadinessMilliseconds: Double
    ) {
        self.url = url
        self.label = label
        self.telemetry = telemetry
        self.configuration = configuration
        self.routeReadinessMilliseconds = routeReadinessMilliseconds
    }

    func run() async {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 393, height: 852),
            configuration: configuration
        )
        webView.navigationDelegate = self
        self.webView = webView
        start = ContinuousClock.now
        telemetryStart = telemetry.snapshot()

        await withCheckedContinuation { continuation in
            self.continuation = continuation
            timeoutTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: .seconds(75))
                } catch {
                    return
                }
                self?.complete(error: "timeout")
            }

            let request = URLRequest(
                url: url,
                cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                timeoutInterval: 70
            )
            webView.load(request)
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        commitMilliseconds = elapsedMilliseconds()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let finishMilliseconds = elapsedMilliseconds()
        Task { @MainActor [weak self, weak webView] in
            guard let self, let webView else { return }

            do {
                let value = try await webView.evaluateJavaScript(Self.metricsScript)
                guard let metricsJson = value as? String,
                      let data = metricsJson.data(using: .utf8),
                      var metrics = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    complete(error: "invalid navigation metrics")
                    return
                }
                metrics["label"] = label
                metrics["requestedUrl"] = url.absoluteString
                metrics["driverCommitMs"] = commitMilliseconds
                metrics["driverFinishMs"] = finishMilliseconds
                complete(metrics: metrics)
            } catch {
                complete(error: "metrics evaluation: \(error.localizedDescription)")
            }
        }
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        complete(error: "provisional navigation: \(error.localizedDescription)")
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        complete(error: "navigation: \(error.localizedDescription)")
    }

    private func elapsedMilliseconds() -> Double {
        let duration = start.duration(to: ContinuousClock.now)
        return Double(duration.components.seconds) * 1_000
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000
    }

    private func complete(error: String) {
        complete(metrics: PhysicalPageBenchmarkResult.errorMetrics(
            label: label,
            requestedUrl: url.absoluteString,
            error: error,
            driverCommitMilliseconds: commitMilliseconds,
            driverFinishMilliseconds: elapsedMilliseconds()
        ))
    }

    private func complete(metrics originalMetrics: [String: Any]) {
        guard let continuation else { return }
        self.continuation = nil
        var metrics = originalMetrics
        metrics["benchmarkRoute"] = configuration.route.rawValue
        metrics["expectedTransportMode"] = configuration.transportMode
            ?? "current"
        metrics["routeReadinessMs"] = routeReadinessMilliseconds
        if let telemetryStart {
            metrics["physicalTelemetry"] = telemetry.result(
                since: telemetryStart
            )
        }
        self.telemetryStart = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil

        if let json = PhysicalPageBenchmarkResult.jsonString(metrics) {
            for line in PhysicalPageBenchmarkResult.logLines(json: json) {
                NSLog("%@", line)
            }
        } else {
            NSLog("[PhysicalPageBenchmark] result serialization failed label=%@", label)
        }
        continuation.resume()
    }

    private static let metricsScript = """
    JSON.stringify((() => {
        const navigation = performance.getEntriesByType("navigation")[0];
        const resources = performance.getEntriesByType("resource");
        const origins = new Set();
        const events = [];
        const dnsEvents = [];
        const resourceTtfbValues = [];
        let totalResourceDnsMs = 0;
        let resourcesWithDns = 0;
        let totalTransferBytes = 0;
        for (const resource of resources) {
            try {
                origins.add(new URL(resource.name).origin);
            } catch (_) {}
            events.push([resource.startTime, 1]);
            events.push([resource.responseEnd, -1]);
            if (resource.domainLookupEnd > resource.domainLookupStart) {
                totalResourceDnsMs += resource.domainLookupEnd - resource.domainLookupStart;
                resourcesWithDns += 1;
                dnsEvents.push([resource.domainLookupStart, 1]);
                dnsEvents.push([resource.domainLookupEnd, -1]);
            }
            if (resource.responseStart > resource.startTime) {
                resourceTtfbValues.push(resource.responseStart - resource.startTime);
            }
            totalTransferBytes += resource.transferSize || 0;
        }
        events.sort((a, b) => a[0] - b[0] || a[1] - b[1]);
        let active = 0;
        let maxRequestConcurrency = 0;
        for (const event of events) {
            active += event[1];
            maxRequestConcurrency = Math.max(maxRequestConcurrency, active);
        }
        dnsEvents.sort((a, b) => a[0] - b[0] || a[1] - b[1]);
        let activeDns = 0;
        let maxDnsConcurrency = 0;
        for (const event of dnsEvents) {
            activeDns += event[1];
            maxDnsConcurrency = Math.max(maxDnsConcurrency, activeDns);
        }
        resourceTtfbValues.sort((a, b) => a - b);
        const percentile = (values, fraction) => {
            if (values.length === 0) {
                return null;
            }
            const index = Math.min(
                values.length - 1,
                Math.max(0, Math.ceil(values.length * fraction) - 1)
            );
            return values[index];
        };
        const navigationMetrics = navigation ? {
            dnsMs: navigation.domainLookupEnd - navigation.domainLookupStart,
            connectMs: navigation.connectEnd - navigation.connectStart,
            tlsMs: navigation.secureConnectionStart > 0
                ? navigation.connectEnd - navigation.secureConnectionStart
                : 0,
            ttfbMs: navigation.responseStart - navigation.startTime,
            responseEndMs: navigation.responseEnd - navigation.startTime,
            domContentLoadedMs:
                navigation.domContentLoadedEventEnd - navigation.startTime,
            loadMs: navigation.loadEventEnd - navigation.startTime,
            transferBytes: navigation.transferSize || 0,
            protocol: navigation.nextHopProtocol || "",
        } : null;
        return {
            finalUrl: location.href,
            navigation: navigationMetrics,
            resourceCount: resources.length,
            originCount: origins.size,
            maxRequestConcurrency,
            maxDnsConcurrency,
            resourcesWithDns,
            totalResourceDnsMs,
            resourceTtfbMedianMs: percentile(resourceTtfbValues, 0.5),
            resourceTtfbP95Ms: percentile(resourceTtfbValues, 0.95),
            resourceTtfbMaxMs: percentile(resourceTtfbValues, 1),
            totalTransferBytes,
        };
    })())
    """
}

/**
 * Opt-in driver for physical-device peer tests.
 *
 * The normal app path is unchanged unless a developer launches the Debug app
 * with URNETWORK_PHYSICAL_TEST_ACTION in its environment. This gives command
 * line device tests a deterministic way to change roles without relying on
 * screen coordinates or leaving a production URL/deep-link control surface.
 */
@MainActor
enum PhysicalPeerTestDriver {
    private static var started = false

    @MainActor
    private struct BenchmarkRoutePreparation {
        let pinnedDevice: SdkDeviceRemote?
        let transportSettingsToRestore: SdkTransportSettings?
        let reconnectLocation: SdkConnectLocation?

        func restore(
            deviceManager: DeviceManager,
            connectViewModel: ConnectViewModel
        ) async -> Bool {
            if let pinnedDevice,
               let transportSettingsToRestore {
                pinnedDevice.setTransportSettings(transportSettingsToRestore)
                NSLog(
                    "[PhysicalPeerTest] transport pin restored mode=%@",
                    transportSettingsToRestore.mode
                )
            }

            guard let reconnectLocation else { return true }
            connectViewModel.connect(reconnectLocation)
            guard let vpnManager = deviceManager.vpnManager else { return false }
            let updateResult = await vpnManager.updateVpnServiceAndWait()
            if case .failure = updateResult { return false }

            let expectedPeerId = reconnectLocation.connectLocationId?
                .clientId?.idStr
            let deadline = ContinuousClock.now + .seconds(60)
            while ContinuousClock.now < deadline {
                let selectedPeerId = connectViewModel.selectedProvider?
                    .connectLocationId?.clientId?.idStr
                if PhysicalPeerTestReadiness.benchmarkIsReady(
                    connectionStatus: connectViewModel.connectionStatus?.rawValue,
                    tunnelConnected: connectViewModel.tunnelConnected,
                    selectedPeerId: selectedPeerId,
                    expectedPeerId: expectedPeerId,
                    route: .vpn
                ) {
                    NSLog(
                        "[PhysicalPeerTest] direct route restored peer=%@",
                        expectedPeerId ?? "best-available"
                    )
                    return true
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return false
        }
    }

    static func runIfRequested(
        deviceManager: DeviceManager,
        connectViewModel: ConnectViewModel,
        networkPeersStore: NetworkPeersStore
    ) {
        guard !started else { return }
        let processInfo = ProcessInfo.processInfo
        guard let action = processInfo.environment["URNETWORK_PHYSICAL_TEST_ACTION"]
                ?? argumentValue("--urnetwork-physical-test-action", in: processInfo.arguments),
              !action.isEmpty else {
            return
        }
        let peerId = processInfo.environment["URNETWORK_PHYSICAL_TEST_PEER_ID"]
            ?? argumentValue("--urnetwork-physical-test-peer", in: processInfo.arguments)
        let benchmarkUrl = processInfo.environment["URNETWORK_PHYSICAL_TEST_URL"]
            ?? argumentValue("--urnetwork-physical-test-url", in: processInfo.arguments)
        let benchmarkLabel = processInfo.environment["URNETWORK_PHYSICAL_TEST_LABEL"]
            ?? argumentValue("--urnetwork-physical-test-label", in: processInfo.arguments)
        let benchmarkSuite = processInfo.environment["URNETWORK_PHYSICAL_TEST_SUITE"]
            ?? argumentValue("--urnetwork-physical-test-suite", in: processInfo.arguments)
        let benchmarkRoute = processInfo.environment["URNETWORK_PHYSICAL_TEST_ROUTE"]
            ?? argumentValue("--urnetwork-physical-test-route", in: processInfo.arguments)
        let benchmarkTransport = processInfo.environment["URNETWORK_PHYSICAL_TEST_TRANSPORT"]
            ?? argumentValue("--urnetwork-physical-test-transport", in: processInfo.arguments)

        started = true
        Task {
            await deviceManager.waitForDeviceInitialization()
            guard deviceManager.device != nil else {
                NSLog("[PhysicalPeerTest] no initialized device for action=%@", action)
                return
            }
            await run(
                action: action,
                peerId: peerId,
                benchmarkUrl: benchmarkUrl,
                benchmarkLabel: benchmarkLabel,
                benchmarkSuite: benchmarkSuite,
                benchmarkRoute: benchmarkRoute,
                benchmarkTransport: benchmarkTransport,
                deviceManager: deviceManager,
                connectViewModel: connectViewModel,
                networkPeersStore: networkPeersStore
            )
        }
    }

    private static func run(
        action: String,
        peerId: String?,
        benchmarkUrl: String?,
        benchmarkLabel: String?,
        benchmarkSuite: String?,
        benchmarkRoute: String?,
        benchmarkTransport: String?,
        deviceManager: DeviceManager,
        connectViewModel: ConnectViewModel,
        networkPeersStore: NetworkPeersStore
    ) async {
        NSLog("[PhysicalPeerTest] action=%@", action)

        switch action {
        case "provide":
            deviceManager.allowProvidingCell = true
            deviceManager.setProvideControlMode(.Always)
            NSLog("[PhysicalPeerTest] provider requested on all networks")

        case "disconnect":
            connectViewModel.disconnect()
            NSLog("[PhysicalPeerTest] disconnect requested")

        case "connect":
            guard let peerId,
                  !peerId.isEmpty else {
                NSLog("[PhysicalPeerTest] connect missing peer id")
                return
            }

            let deadline = ContinuousClock.now + .seconds(60)
            while ContinuousClock.now < deadline {
                if let peer = networkPeersStore.connectedProvidePeers.first(where: {
                    $0.clientId.idStr == peerId
                }) {
                    connectViewModel.connect(peer.toConnectLocation())
                    NSLog("[PhysicalPeerTest] connect requested peer=%@", peerId)
                    await logStatus(
                        deviceManager: deviceManager,
                        connectViewModel: connectViewModel,
                        delays: [.seconds(1), .seconds(3), .seconds(10)]
                    )
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
            NSLog(
                "[PhysicalPeerTest] peer discovery timeout peer=%@ visible=%@",
                peerId,
                networkPeersStore.connectedProvidePeers.map(\.clientId.idStr).joined(separator: ",")
            )

        case "benchmark", "benchmark-suite":
            guard let configuration = PhysicalBenchmarkConfiguration.resolve(
                routeValue: benchmarkRoute,
                transportValue: benchmarkTransport,
                expectedPeerId: peerId
            ) else {
                NSLog(
                    "[PhysicalPeerTest] benchmark invalid route=%@ transport=%@ peer=%@",
                    benchmarkRoute ?? "vpn",
                    benchmarkTransport ?? "current",
                    peerId ?? "none"
                )
                return
            }
            let requests: [PhysicalPageBenchmarkRequest]
            if action == "benchmark-suite" {
                guard let benchmarkSuite,
                      let suiteRequests = PhysicalPageBenchmarkSuite.requests(
                        json: benchmarkSuite
                      ) else {
                    NSLog("[PhysicalPeerTest] benchmark suite missing valid JSON requests")
                    return
                }
                requests = suiteRequests
            } else {
                guard let benchmarkUrl,
                      let url = URL(string: benchmarkUrl),
                      let scheme = url.scheme,
                      ["http", "https"].contains(scheme.lowercased()) else {
                    NSLog("[PhysicalPeerTest] benchmark missing valid http(s) url")
                    return
                }
                requests = [
                    PhysicalPageBenchmarkRequest(
                        urlString: url.absoluteString,
                        label: benchmarkLabel ?? url.host() ?? "page"
                    ),
                ]
            }
            NSLog(
                "[PhysicalPeerTest] benchmark requests=%d route=%@ transport=%@",
                requests.count,
                configuration.route.rawValue,
                configuration.transportMode ?? "current"
            )
            for request in requests {
                NSLog(
                    "[PhysicalPeerTest] benchmark requested label=%@ url=%@",
                    request.label,
                    request.urlString
                )
            }
            let routeReadinessStart = ContinuousClock.now
            guard let routePreparation = await prepareBenchmarkRoute(
                configuration: configuration,
                deviceManager: deviceManager,
                connectViewModel: connectViewModel
            ) else {
                NSLog("[PhysicalPeerTest] benchmark route preparation failed")
                NSLog(
                    "[PhysicalPeerTest] benchmark session complete route=%@ transport=%@",
                    configuration.route.rawValue,
                    configuration.transportMode ?? "current"
                )
                return
            }
            await runPreparedBenchmark(
                requests: requests,
                expectedPeerId: peerId,
                configuration: configuration,
                deviceManager: deviceManager,
                connectViewModel: connectViewModel,
                routeReadinessStart: routeReadinessStart
            )
            let restoreSucceeded = await routePreparation.restore(
                deviceManager: deviceManager,
                connectViewModel: connectViewModel
            )
            if !restoreSucceeded {
                NSLog("[PhysicalPeerTest] benchmark route restore failed")
            }
            NSLog(
                "[PhysicalPeerTest] benchmark session complete route=%@ transport=%@",
                configuration.route.rawValue,
                configuration.transportMode ?? "current"
            )

        case "status":
            NSLog("[PhysicalPeerTest] status requested")

        default:
            NSLog("[PhysicalPeerTest] unknown action=%@", action)
        }

        await logStatus(
            deviceManager: deviceManager,
            connectViewModel: connectViewModel,
            delays: [.seconds(1), .seconds(3), .seconds(10)]
        )
    }

    private static func runPreparedBenchmark(
        requests: [PhysicalPageBenchmarkRequest],
        expectedPeerId: String?,
        configuration: PhysicalBenchmarkConfiguration,
        deviceManager: DeviceManager,
        connectViewModel: ConnectViewModel,
        routeReadinessStart: ContinuousClock.Instant
    ) async {
        guard await waitForBenchmarkReadiness(
            expectedPeerId: expectedPeerId,
            configuration: configuration,
            deviceManager: deviceManager,
            connectViewModel: connectViewModel
        ) else {
            let selectedPeerId = connectViewModel.selectedProvider?
                .connectLocationId?.clientId?.idStr ?? "none"
            NSLog(
                "[PhysicalPeerTest] benchmark readiness timeout route=%@ transport=%@ actualTransport=%@ connect=%@ tunnel=%@ selected=%@ expected=%@",
                configuration.route.rawValue,
                configuration.transportMode ?? "current",
                deviceManager.device?.getTransportSettings()?.mode ?? "unknown",
                connectViewModel.connectionStatus?.rawValue ?? "unknown",
                connectViewModel.tunnelConnected.description,
                selectedPeerId,
                expectedPeerId ?? "any"
            )
            return
        }
        let readinessDuration = routeReadinessStart.duration(
            to: ContinuousClock.now
        )
        let readinessMilliseconds =
            Double(readinessDuration.components.seconds) * 1_000
            + Double(readinessDuration.components.attoseconds)
                / 1_000_000_000_000_000
        NSLog(
            "[PhysicalPeerTest] benchmark route ready waitMs=%.3f route=%@ transport=%@ peer=%@",
            readinessMilliseconds,
            configuration.route.rawValue,
            configuration.transportMode ?? "current",
            expectedPeerId ?? "any"
        )
        guard let device = deviceManager.device else {
            NSLog("[PhysicalPeerTest] benchmark lost initialized device")
            return
        }
        let telemetry = PhysicalBenchmarkTelemetry(device: device)
        defer { telemetry.close() }
        for request in requests {
            guard let url = URL(string: request.urlString) else { continue }
            let benchmark = PhysicalPageBenchmark(
                url: url,
                label: request.label,
                telemetry: telemetry,
                configuration: configuration,
                routeReadinessMilliseconds: readinessMilliseconds
            )
            await benchmark.run()
        }
    }

    private static func prepareBenchmarkRoute(
        configuration: PhysicalBenchmarkConfiguration,
        deviceManager: DeviceManager,
        connectViewModel: ConnectViewModel
    ) async -> BenchmarkRoutePreparation? {
        switch configuration.route {
        case .direct:
            // Direct means no Network Extension, not merely no selected exit.
            // Use the same non-destructive reconcile as DisconnectIntent so
            // the installed profile and RPC credentials remain available for
            // the next VPN sample.
            if deviceManager.providingPublicly {
                NSLog("[PhysicalPeerTest] direct route has active providing")
                return nil
            }
            let connectionWasActive = PhysicalPeerTestReadiness
                .shouldRestoreConnectionAfterDirect(
                    connectionStatus: connectViewModel.connectionStatus?.rawValue,
                    tunnelConnected: connectViewModel.tunnelConnected
                )
            let reconnectLocation = connectionWasActive
                ? deviceManager.device?.getConnectLocation()
                : nil
            if connectionWasActive && reconnectLocation == nil {
                NSLog("[PhysicalPeerTest] direct route cannot snapshot connection")
                return nil
            }
            let preparation = BenchmarkRoutePreparation(
                pinnedDevice: nil,
                transportSettingsToRestore: nil,
                reconnectLocation: reconnectLocation
            )
            connectViewModel.disconnect()
            if let vpnManager = deviceManager.vpnManager {
                let result = await vpnManager.updateVpnServiceAndWait()
                if case .failure(let error) = result {
                    NSLog(
                        "[PhysicalPeerTest] direct route stop failed error=%@",
                        error.localizedDescription
                    )
                    _ = await preparation.restore(
                        deviceManager: deviceManager,
                        connectViewModel: connectViewModel
                    )
                    return nil
                }
            } else if connectViewModel.tunnelConnected {
                NSLog("[PhysicalPeerTest] direct route has no VPN manager")
                _ = await preparation.restore(
                    deviceManager: deviceManager,
                    connectViewModel: connectViewModel
                )
                return nil
            }
            return preparation

        case .vpn:
            guard let expectedMode = configuration.transportMode else {
                return BenchmarkRoutePreparation(
                    pinnedDevice: nil,
                    transportSettingsToRestore: nil,
                    reconnectLocation: nil
                )
            }
            guard let device = deviceManager.device,
                  let previousSettings = device.getTransportSettings()?.clone(),
                  let settings = previousSettings.clone() else {
                NSLog(
                    "[PhysicalPeerTest] transport pin unavailable expected=%@",
                    expectedMode
                )
                return nil
            }
            if previousSettings.mode == expectedMode {
                NSLog(
                    "[PhysicalPeerTest] transport already pinned mode=%@",
                    expectedMode
                )
                return BenchmarkRoutePreparation(
                    pinnedDevice: nil,
                    transportSettingsToRestore: nil,
                    reconnectLocation: nil
                )
            }
            settings.mode = expectedMode
            device.setTransportSettings(settings)
            NSLog(
                "[PhysicalPeerTest] transport pin requested mode=%@",
                expectedMode
            )
            return BenchmarkRoutePreparation(
                pinnedDevice: device,
                transportSettingsToRestore: previousSettings,
                reconnectLocation: nil
            )
        }
    }

    private static func waitForBenchmarkReadiness(
        expectedPeerId: String?,
        configuration: PhysicalBenchmarkConfiguration,
        deviceManager: DeviceManager,
        connectViewModel: ConnectViewModel
    ) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(60)
        while ContinuousClock.now < deadline {
            let selectedPeerId = connectViewModel.selectedProvider?
                .connectLocationId?.clientId?.idStr
            if PhysicalPeerTestReadiness.benchmarkIsReady(
                connectionStatus: connectViewModel.connectionStatus?.rawValue,
                tunnelConnected: connectViewModel.tunnelConnected,
                selectedPeerId: selectedPeerId,
                expectedPeerId: expectedPeerId,
                route: configuration.route,
                transportMode: deviceManager.device?
                    .getTransportSettings()?.mode,
                expectedTransportMode: configuration.transportMode
            ) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    private static func logStatus(
        deviceManager: DeviceManager,
        connectViewModel: ConnectViewModel,
        delays: [Duration]
    ) async {
        for delay in delays {
            try? await Task.sleep(for: delay)
            NSLog(
                "[PhysicalPeerTest] status client=%@ connect=%@ tunnel=%@ provide=%@ paused=%@",
                deviceManager.device?.getClientId()?.idStr ?? "unknown",
                connectViewModel.connectionStatus?.rawValue ?? "unknown",
                connectViewModel.tunnelConnected.description,
                deviceManager.providingPublicly.description,
                deviceManager.providePaused.description
            )
        }
    }

    private static func argumentValue(_ name: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: name) else { return nil }
        let valueIndex = arguments.index(after: index)
        guard valueIndex < arguments.endIndex else { return nil }
        return arguments[valueIndex]
    }
}

#endif

#endif
