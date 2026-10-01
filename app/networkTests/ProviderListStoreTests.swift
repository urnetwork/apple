import Combine
import Foundation
import XCTest
import URnetworkSdk
@testable import URnetwork

// Hold the real store's service callbacks explicitly. No production API,
// device, token or network is involved, and callbacks resume outside the lock.
private final class HeldProviderListService: MockUrApiService {
    private let lock = NSLock()
    private var queries: [String] = []
    private var callbacks: [CheckedContinuation<SdkFilteredLocations, Error>?] = []
    private var requestObserver: ((String) -> Void)?

    var didRequest: ((String) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return requestObserver
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            requestObserver = newValue
        }
    }

    var calls: [String] {
        lock.lock()
        defer { lock.unlock() }
        return queries
    }

    private func hold(_ query: String) async throws -> SdkFilteredLocations {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            queries.append(query)
            callbacks.append(continuation)
            lock.unlock()
            didRequest?(query)
        }
    }

    override func getAllProviders() async throws -> SdkFilteredLocations {
        try await hold("")
    }

    override func searchProviders(_ query: String) async throws -> SdkFilteredLocations {
        try await hold(query)
    }

    func complete(_ index: Int, with result: Result<SdkFilteredLocations, Error>) {
        lock.lock()
        let callback = callbacks[index]
        callbacks[index] = nil
        lock.unlock()
        callback?.resume(with: result)
    }
}

@MainActor
final class ProviderListStoreTests: XCTestCase {
    private func result(_ name: String) -> SdkFilteredLocations {
        let result = SdkFilteredLocations()
        let countries = SdkNewConnectLocationList()!
        let country = SdkConnectLocation()
        country.name = name
        country.locationType = SdkLocationTypeCountry
        countries.add(country)
        result.countries = countries
        return result
    }

    private func requested(_ service: HeldProviderListService, query: String = "") -> XCTestExpectation {
        let started = expectation(description: "request started: \(query)")
        service.didRequest = {
            XCTAssertEqual($0, query)
            started.fulfill()
        }
        return started
    }

    func testInitialPublisherDoesNotFetchBeforePickerAppears() async {
        let service = HeldProviderListService()
        let unexpected = expectation(description: "initial empty publisher must not fetch")
        unexpected.isInverted = true
        service.didRequest = { _ in unexpected.fulfill() }
        let store = ProviderListStore(urApiService: service)
        // Exercise the real Combine publisher beyond its 300ms debounce.
        await fulfillment(of: [unexpected], timeout: 0.45)
        XCTAssertTrue(service.calls.isEmpty)
        XCTAssertFalse(store.providersLoading)

        let started = requested(service)
        let load = Task { await store.filterLocations("") }
        await fulfillment(of: [started], timeout: 2)
        service.complete(0, with: .success(result("Initial country")))
        _ = await load.value
        XCTAssertEqual(service.calls, [""])
        XCTAssertEqual(store.providerCountries.first?.name, "Initial country")
    }

    func testOverlappingInitialLoadsUseOneRequest() async {
        let service = HeldProviderListService()
        let store = ProviderListStore(urApiService: service)
        let started = requested(service)
        let first = Task { await store.filterLocations("") }
        await fulfillment(of: [started], timeout: 2)
        let joined = expectation(description: "second waiter entered")
        let second = Task {
            joined.fulfill()
            return await store.filterLocations(" \n")
        }
        await fulfillment(of: [joined], timeout: 2)
        XCTAssertEqual(service.calls, [""])
        XCTAssertTrue(store.showLoadingPlaceholder)
        service.complete(0, with: .success(result("One shared response")))
        _ = await first.value
        _ = await second.value
        XCTAssertFalse(store.providersLoading)
        XCTAssertEqual(store.providerCountries.first?.name, "One shared response")
    }

    func testPresentationFetchCompletesBeforeExtensionStatusRefresh() async {
        let service = HeldProviderListService()
        let store = ProviderListStore(urApiService: service)
        let model = ConnectViewModel()
        let started = requested(service)
        let readerStarted = expectation(description: "extension reader started")
        let releaseReader = DispatchSemaphore(value: 0)
        defer { releaseReader.signal() }
        var refreshRequested = false
        let load = Task {
            await store.loadForPresentation {
                refreshRequested = true
                model.refreshContractStatus {
                    XCTAssertFalse(Thread.isMainThread)
                    readerStarted.fulfill()
                    _ = releaseReader.wait(timeout: .now() + 5)
                    return nil
                }
            }
        }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertFalse(refreshRequested, "status RPC must not precede the provider GET")
        service.complete(0, with: .success(result("Visible before extension reply")))
        await load.value
        await fulfillment(of: [readerStarted], timeout: 2)
        XCTAssertEqual(store.providerCountries.first?.name, "Visible before extension reply")
        XCTAssertFalse(store.showLoadingPlaceholder)
        XCTAssertTrue(model.contractStatusRefreshPending)
        releaseReader.signal()
        let deadline = Date().addingTimeInterval(2)
        while model.contractStatusRefreshPending && Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertFalse(model.contractStatusRefreshPending)
    }

    func testFailedPresentationFetchStillRequestsStatusRefresh() async {
        let service = HeldProviderListService()
        let store = ProviderListStore(urApiService: service)
        let started = requested(service)
        var refreshCount = 0
        let load = Task {
            await store.loadForPresentation { refreshCount += 1 }
        }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(refreshCount, 0)
        service.complete(0, with: .failure(NSError(domain: "synthetic", code: 1)))
        await load.value
        XCTAssertEqual(refreshCount, 1)
        XCTAssertFalse(store.providersLoading)
    }

    func testSupersededPresentationReturningAfterSearchDoesNotRefreshStatus() async {
        let service = HeldProviderListService()
        let store = ProviderListStore(urApiService: service)
        let initialStarted = requested(service)
        var refreshCount = 0
        let initial = Task {
            await store.loadForPresentation { refreshCount += 1 }
        }
        await fulfillment(of: [initialStarted], timeout: 2)
        let searchStarted = requested(service, query: "Tokyo")
        let search = Task { await store.filterLocations("Tokyo") }
        await fulfillment(of: [searchStarted], timeout: 2)
        service.complete(1, with: .success(result("Current search")))
        _ = await search.value
        XCTAssertFalse(store.providersLoading)
        service.complete(0, with: .success(result("Late initial")))
        await initial.value
        XCTAssertEqual(refreshCount, 0)
        XCTAssertEqual(store.providerCountries.first?.name, "Current search")
    }

    func testSameQueryRefreshKeepsRowsVisibleAndFailureIsRetryable() async {
        let service = HeldProviderListService()
        let store = ProviderListStore(urApiService: service)
        let initialStarted = requested(service)
        let initial = Task { await store.filterLocations("") }
        await fulfillment(of: [initialStarted], timeout: 2)
        service.complete(0, with: .success(result("Cached country")))
        _ = await initial.value

        let refreshStarted = requested(service)
        let refresh = Task { await store.filterLocations("") }
        await fulfillment(of: [refreshStarted], timeout: 2)
        XCTAssertTrue(store.providersLoading)
        XCTAssertFalse(store.showLoadingPlaceholder)
        XCTAssertEqual(store.providerCountries.first?.name, "Cached country")
        service.complete(1, with: .failure(NSError(domain: "synthetic", code: 1)))
        if case .success = await refresh.value { XCTFail("failed refresh became success") }
        XCTAssertFalse(store.providersLoading)
        XCTAssertEqual(store.providerCountries.first?.name, "Cached country")

        let retryStarted = requested(service)
        let retry = Task { await store.filterLocations("") }
        await fulfillment(of: [retryStarted], timeout: 2)
        service.complete(2, with: .success(result("Fresh country")))
        _ = await retry.value
        XCTAssertEqual(service.calls, ["", "", ""])
        XCTAssertEqual(store.providerCountries.first?.name, "Fresh country")
    }

    func testChangedQueryClearsRowsAndLateInitialCannotReplaceSearch() async {
        let service = HeldProviderListService()
        let store = ProviderListStore(urApiService: service)
        let initialStarted = requested(service)
        let initial = Task { await store.filterLocations("") }
        await fulfillment(of: [initialStarted], timeout: 2)
        service.complete(0, with: .success(result("Cached country")))
        _ = await initial.value

        let refreshStarted = requested(service)
        let refresh = Task { await store.filterLocations("") }
        await fulfillment(of: [refreshStarted], timeout: 2)
        let searchStarted = requested(service, query: "Paris")
        let search = Task { await store.filterLocations("Paris") }
        await fulfillment(of: [searchStarted], timeout: 2)
        XCTAssertTrue(store.providerCountries.isEmpty)
        XCTAssertTrue(store.showLoadingPlaceholder)

        service.complete(1, with: .success(result("Late initial country")))
        _ = await refresh.value
        XCTAssertTrue(store.providersLoading)
        XCTAssertTrue(store.providerCountries.isEmpty)
        service.complete(2, with: .success(result("Current search")))
        _ = await search.value
        XCTAssertFalse(store.providersLoading)
        XCTAssertEqual(store.providerCountries.first?.name, "Current search")
    }

    func testCanceledWaiterDoesNotCancelSharedRequest() async {
        let service = HeldProviderListService()
        let store = ProviderListStore(urApiService: service)
        let started = requested(service)
        let first = Task { await store.filterLocations("") }
        await fulfillment(of: [started], timeout: 2)
        first.cancel()
        let joined = expectation(description: "live waiter joined")
        let second = Task {
            joined.fulfill()
            return await store.filterLocations("")
        }
        await fulfillment(of: [joined], timeout: 2)
        service.complete(0, with: .success(result("Shared live request")))
        _ = await first.value
        _ = await second.value
        XCTAssertEqual(service.calls, [""])
        XCTAssertFalse(store.providersLoading)
        XCTAssertEqual(store.providerCountries.first?.name, "Shared live request")
    }

    func testSupersededResponseAfterNewSuccessCannotReplaceRows() async {
        let service = HeldProviderListService()
        let store = ProviderListStore(urApiService: service)
        let oldStarted = requested(service)
        let old = Task { await store.filterLocations("") }
        await fulfillment(of: [oldStarted], timeout: 2)
        let currentStarted = requested(service, query: "Tokyo")
        let current = Task { await store.filterLocations("Tokyo") }
        await fulfillment(of: [currentStarted], timeout: 2)
        service.complete(1, with: .success(result("Current search")))
        _ = await current.value
        service.complete(0, with: .success(result("Late initial response")))
        _ = await old.value
        XCTAssertFalse(store.providersLoading)
        XCTAssertEqual(store.providerCountries.first?.name, "Current search")
    }

    func testPreCanceledCallerDoesNotStartRequest() async {
        let service = HeldProviderListService()
        let store = ProviderListStore(urApiService: service)
        let canceled = Task { await store.filterLocations("") }
        canceled.cancel()
        if case .success = await canceled.value { XCTFail("pre-canceled caller became success") }
        XCTAssertTrue(service.calls.isEmpty)
        XCTAssertFalse(store.providersLoading)
    }

    func testTypingAfterAppearanceStillUsesDebouncedSearch() async {
        let service = HeldProviderListService()
        let store = ProviderListStore(urApiService: service)
        let started = requested(service, query: "Tokyo")
        store.searchQuery = "Tokyo"
        await fulfillment(of: [started], timeout: 2)
        let loaded = expectation(description: "search loaded")
        let subscription = store.$providersLoading.dropFirst().filter { !$0 }.sink { _ in loaded.fulfill() }
        service.complete(0, with: .success(result("Typed search")))
        await fulfillment(of: [loaded], timeout: 2)
        withExtendedLifetime(subscription) {}
        XCTAssertEqual(service.calls, ["Tokyo"])
        XCTAssertEqual(store.providerCountries.first?.name, "Typed search")
    }

    func testReturningToLastQuerySupersedesHeldDifferentQuery() async {
        let service = HeldProviderListService()
        let store = ProviderListStore(urApiService: service)
        let initialStarted = requested(service, query: "Tokyo")
        let initial = Task { await store.filterLocations("Tokyo") }
        await fulfillment(of: [initialStarted], timeout: 2)
        service.complete(0, with: .success(result("Initial Tokyo")))
        _ = await initial.value

        // Use the real debounced publisher: this exercises performSearch's
        // completed-query check as well as the request generation fence.
        let parisStarted = requested(service, query: "Paris")
        store.searchQuery = "Paris"
        await fulfillment(of: [parisStarted], timeout: 2)
        let parisJoined = expectation(description: "held Paris waiter joined")
        let paris = Task {
            parisJoined.fulfill()
            return await store.filterLocations("Paris")
        }
        await fulfillment(of: [parisJoined], timeout: 2)

        let tokyoStarted = requested(service, query: "Tokyo")
        store.searchQuery = "Tokyo"
        await fulfillment(of: [tokyoStarted], timeout: 2)
        let tokyoJoined = expectation(description: "current Tokyo waiter joined")
        let tokyo = Task {
            tokyoJoined.fulfill()
            return await store.filterLocations("Tokyo")
        }
        await fulfillment(of: [tokyoJoined], timeout: 2)
        XCTAssertEqual(service.calls, ["Tokyo", "Paris", "Tokyo"])

        service.complete(2, with: .success(result("Current Tokyo")))
        _ = await tokyo.value
        service.complete(1, with: .success(result("Late Paris")))
        _ = await paris.value
        XCTAssertEqual(store.searchQuery, "Tokyo")
        XCTAssertEqual(store.providerCountries.first?.name, "Current Tokyo")
        XCTAssertFalse(store.providersLoading)
    }
}
