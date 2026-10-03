import XCTest
@testable import URnetwork

// The snackbar hid every message after 3 seconds. A long server message, like
// the App Store refusal of an account deletion, disappeared before it could be
// read. The hide is recorded instead of scheduled, so no time passes.
@MainActor
final class UrSnackbarManagerTests: XCTestCase {

    // the server's App Store refusal (server controller/network_remove_providers.go)
    private let appStoreRefusal = "Your subscription is billed through the App Store and cannot be cancelled by URnetwork. Cancel it in your App Store subscriptions (Settings > your name > Subscriptions), then delete your account."

    private var scheduled: [(seconds: TimeInterval, hide: @MainActor () -> Void)] = []

    private func manager() -> UrSnackbarManager {
        scheduled = []
        return UrSnackbarManager(scheduleHide: { [unowned self] seconds, hide in
            self.scheduled.append((seconds, hide))
        })
    }

    func testLongMessageStaysUpLongEnoughToRead() {
        let snackbar = manager()

        snackbar.showSnackbar(message: appStoreRefusal)

        XCTAssertEqual(scheduled.count, 1)
        // about 15 characters a second
        let readingSeconds = Double(appStoreRefusal.count) / 15
        XCTAssertGreaterThanOrEqual(scheduled[0].seconds, readingSeconds, "a \(appStoreRefusal.count)-character message hides after \(scheduled[0].seconds) s")
    }

    func testShortMessageKeepsTheShortDisplay() {
        let snackbar = manager()

        snackbar.showSnackbar(message: "Copied")

        XCTAssertEqual(scheduled.map(\.seconds), [3])
    }

    func testDisplayTimeIsCapped() {
        XCTAssertLessThanOrEqual(UrSnackbarManager.displaySeconds(for: String(repeating: "a", count: 5_000)), 20)
    }

    func testHideHidesTheMessage() {
        let snackbar = manager()

        snackbar.showSnackbar(message: "Copied")
        XCTAssertTrue(snackbar.isVisible)
        scheduled[0].hide()

        XCTAssertFalse(snackbar.isVisible)
    }

    func testEarlierHideDoesNotHideANewerMessage() {
        let snackbar = manager()

        snackbar.showSnackbar(message: "Copied")
        snackbar.showSnackbar(message: appStoreRefusal)
        scheduled[0].hide()

        XCTAssertTrue(snackbar.isVisible)
        XCTAssertEqual(snackbar.message, appStoreRefusal)
        scheduled[1].hide()
        XCTAssertFalse(snackbar.isVisible)
    }

    func testDismissHidesAtOnce() {
        let snackbar = manager()

        snackbar.showSnackbar(message: appStoreRefusal)
        snackbar.dismiss()

        XCTAssertFalse(snackbar.isVisible)
    }
}
