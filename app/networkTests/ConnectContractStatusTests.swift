import Combine
import Foundation
import XCTest
import URnetworkSdk
@testable import URnetwork

@MainActor
final class ConnectContractStatusTests: XCTestCase {
    private func status(premium: Bool = false, noPermission: Bool = false) -> SdkContractStatus {
        let status = SdkContractStatus()
        status.premium = premium
        status.noPermission = noPermission
        return status
    }

    private func waitForRefresh(_ model: ConnectViewModel) async {
        let deadline = Date().addingTimeInterval(2)
        while model.contractStatusRefreshPending && Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertFalse(model.contractStatusRefreshPending)
    }

    func testSlowGetterLeavesMainActorAvailableAndCoalescesRefreshes() async {
        let model = ConnectViewModel()
        let started = expectation(description: "background getter started")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let value = status(premium: true)
        model.refreshContractStatus {
            XCTAssertFalse(Thread.isMainThread)
            started.fulfill()
            _ = release.wait(timeout: .now() + 5)
            return value
        }
        await fulfillment(of: [started], timeout: 2)
        model.refreshContractStatus {
            XCTFail("overlapping refresh created another blocking SDK read")
            return nil
        }
        let mainTurn = expectation(description: "main actor remains available")
        DispatchQueue.main.async { mainTurn.fulfill() }
        await fulfillment(of: [mainTurn], timeout: 2)
        XCTAssertNil(model.contractStatus)
        release.signal()
        await waitForRefresh(model)
        XCTAssertEqual(model.contractStatus?.premium, true)
    }

    func testPushedStatusSupersedesAnOlderHeldGetter() async {
        let model = ConnectViewModel()
        let started = expectation(description: "older getter held")
        let updated = expectation(description: "notification applied")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let older = status()
        model.refreshContractStatus {
            started.fulfill()
            _ = release.wait(timeout: .now() + 5)
            return older
        }
        await fulfillment(of: [started], timeout: 2)
        let sub = model.$contractStatus.dropFirst().sink { value in
            if value?.noPermission == true { updated.fulfill() }
        }
        let listener = model.makeContractStatusListener()
        listener.contractStatusChanged(status(noPermission: true))
        // A listener applies its supplied value while the only getter is held.
        await fulfillment(of: [updated], timeout: 2)
        release.signal()
        await waitForRefresh(model)
        XCTAssertEqual(model.contractStatus?.noPermission, true)
        withExtendedLifetime(sub) {}
    }

    func testResetRejectsAQueuedNotificationAndInFlightGetter() async {
        let model = ConnectViewModel()
        let listener = model.makeContractStatusListener()
        let started = expectation(description: "getter held across reset")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let value = status(premium: true)
        model.refreshContractStatus {
            started.fulfill()
            _ = release.wait(timeout: .now() + 5)
            return value
        }
        await fulfillment(of: [started], timeout: 2)
        listener.contractStatusChanged(value)
        model.reset()
        release.signal()
        await waitForRefresh(model)
        XCTAssertNil(model.contractStatus)
    }

    func testReplacementRefreshStartsBeforeRetiredGetterFinishes() async {
        let model = ConnectViewModel()
        let oldStarted = expectation(description: "retired getter held")
        let newStarted = expectation(description: "replacement getter started")
        let published = expectation(description: "replacement published")
        let releaseOld = DispatchSemaphore(value: 0)
        defer { releaseOld.signal() }
        let oldValue = status()
        let newValue = status(premium: true)
        model.refreshContractStatus {
            oldStarted.fulfill()
            _ = releaseOld.wait(timeout: .now() + 5)
            return oldValue
        }
        await fulfillment(of: [oldStarted], timeout: 2)
        model.reset()
        let sub = model.$contractStatus.dropFirst().sink { value in
            if value?.premium == true { published.fulfill() }
        }
        model.refreshContractStatus {
            newStarted.fulfill()
            return newValue
        }
        await fulfillment(of: [newStarted, published], timeout: 2)
        XCTAssertTrue(model.contractStatusRefreshPending, "old getter should still be held")
        releaseOld.signal()
        await waitForRefresh(model)
        XCTAssertEqual(model.contractStatus?.premium, true)
        withExtendedLifetime(sub) {}
    }

    func testRapidReplacementBoundsReadsAndKeepsOnlyNewestQueuedGeneration() async {
        let model = ConnectViewModel()
        let firstStarted = expectation(description: "first getter held")
        let secondStarted = expectation(description: "second getter held")
        let newestStarted = expectation(description: "newest queued getter started")
        let releaseFirst = DispatchSemaphore(value: 0)
        let releaseSecond = DispatchSemaphore(value: 0)
        defer { releaseFirst.signal(); releaseSecond.signal() }
        let newestValue = status(premium: true)
        model.refreshContractStatus {
            firstStarted.fulfill()
            _ = releaseFirst.wait(timeout: .now() + 5)
            return nil
        }
        await fulfillment(of: [firstStarted], timeout: 2)
        model.reset()
        model.refreshContractStatus {
            secondStarted.fulfill()
            _ = releaseSecond.wait(timeout: .now() + 5)
            return nil
        }
        await fulfillment(of: [secondStarted], timeout: 2)
        model.reset()
        model.refreshContractStatus {
            XCTFail("third concurrent or retired queued getter started")
            return nil
        }
        model.reset()
        model.refreshContractStatus {
            newestStarted.fulfill()
            return newestValue
        }
        releaseFirst.signal()
        await fulfillment(of: [newestStarted], timeout: 2)
        releaseSecond.signal()
        await waitForRefresh(model)
        XCTAssertEqual(model.contractStatus?.premium, true)
    }

    func testEqualNotificationsDoNotRepublishAndNilStillClears() async {
        let model = ConnectViewModel()
        let listener = model.makeContractStatusListener()
        let first = expectation(description: "first status published")
        let cleared = expectation(description: "nil status published")
        var publicationCount = 0
        let sub = model.$contractStatus.dropFirst().sink { value in
            publicationCount += 1
            if value == nil { cleared.fulfill() } else { first.fulfill() }
        }
        listener.contractStatusChanged(status(premium: true))
        await fulfillment(of: [first], timeout: 2)
        listener.contractStatusChanged(status(premium: true))
        listener.contractStatusChanged(nil)
        await fulfillment(of: [cleared], timeout: 2)
        XCTAssertEqual(publicationCount, 2)
        XCTAssertNil(model.contractStatus)
        withExtendedLifetime(sub) {}
    }
}
