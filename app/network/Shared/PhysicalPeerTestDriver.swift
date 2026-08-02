#if DEBUG

import Foundation

enum PhysicalPageBenchmarkResult {
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
}

enum PhysicalPeerTestReadiness {
    static func benchmarkIsReady(
        connectionStatus: String?,
        tunnelConnected: Bool,
        selectedPeerId: String?,
        expectedPeerId: String?
    ) -> Bool {
        guard connectionStatus == "CONNECTED", tunnelConnected else {
            return false
        }
        guard let expectedPeerId, !expectedPeerId.isEmpty else {
            return true
        }
        return selectedPeerId == expectedPeerId
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

import URnetworkSdk
import WebKit

@MainActor
private final class PhysicalPageBenchmark: NSObject, WKNavigationDelegate {
    private let url: URL
    private let label: String
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var start = ContinuousClock.now
    private var commitMilliseconds: Double?

    init(url: URL, label: String) {
        self.url = url
        self.label = label
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

    private func complete(metrics: [String: Any]) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil

        if let json = PhysicalPageBenchmarkResult.jsonString(metrics) {
            NSLog("[PhysicalPageBenchmark] %@", json)
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
            NSLog("[PhysicalPeerTest] benchmark requests=%d", requests.count)
            for request in requests {
                NSLog(
                    "[PhysicalPeerTest] benchmark requested label=%@ url=%@",
                    request.label,
                    request.urlString
                )
            }
            let readinessStart = ContinuousClock.now
            guard await waitForBenchmarkReadiness(
                expectedPeerId: peerId,
                connectViewModel: connectViewModel
            ) else {
                let selectedPeerId = connectViewModel.selectedProvider?
                    .connectLocationId?.clientId?.idStr ?? "none"
                NSLog(
                    "[PhysicalPeerTest] benchmark readiness timeout connect=%@ tunnel=%@ selected=%@ expected=%@",
                    connectViewModel.connectionStatus?.rawValue ?? "unknown",
                    connectViewModel.tunnelConnected.description,
                    selectedPeerId,
                    peerId ?? "any"
                )
                return
            }
            let readinessDuration = readinessStart.duration(to: ContinuousClock.now)
            let readinessMilliseconds =
                Double(readinessDuration.components.seconds) * 1_000
                + Double(readinessDuration.components.attoseconds)
                    / 1_000_000_000_000_000
            NSLog(
                "[PhysicalPeerTest] benchmark route ready waitMs=%.3f peer=%@",
                readinessMilliseconds,
                peerId ?? "any"
            )
            for request in requests {
                guard let url = URL(string: request.urlString) else {
                    continue
                }
                let benchmark = PhysicalPageBenchmark(
                    url: url,
                    label: request.label
                )
                await benchmark.run()
            }

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

    private static func waitForBenchmarkReadiness(
        expectedPeerId: String?,
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
                expectedPeerId: expectedPeerId
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
