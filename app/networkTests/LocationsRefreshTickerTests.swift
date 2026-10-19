import XCTest
@testable import URnetwork

/// Virtual time: repeating timers fire only when the test advances the clock.
@MainActor
private final class ManualTimerScheduler {
    private final class ManualTimer: RefreshTimer {
        let interval: TimeInterval
        let action: @MainActor () -> Void
        var nextFire: TimeInterval
        var cancelled = false

        init(interval: TimeInterval, start: TimeInterval, action: @escaping @MainActor () -> Void) {
            self.interval = interval
            self.action = action
            self.nextFire = start + interval
        }

        func cancel() {
            cancelled = true
        }
    }

    private var now: TimeInterval = 0
    private var timers: [ManualTimer] = []

    var schedule: RefreshTimerScheduler {
        { [unowned self] interval, action in
            let timer = ManualTimer(interval: interval, start: self.now, action: action)
            self.timers.append(timer)
            return timer
        }
    }

    func advance(_ seconds: TimeInterval) {
        let end = now + seconds
        while let timer = timers.filter({ !$0.cancelled && $0.nextFire <= end })
            .min(by: { $0.nextFire < $1.nextFire }) {
            now = timer.nextFire
            timer.nextFire += timer.interval
            timer.action()
        }
        now = end
    }
}

@MainActor
final class LocationsRefreshTickerTests: XCTestCase {

    private var scheduler: ManualTimerScheduler!
    private var fetches = 0
    private var fetching = false
    private var ticker: LocationsRefreshTicker!

    override func setUp() async throws {
        scheduler = ManualTimerScheduler()
        fetches = 0
        fetching = false
        ticker = LocationsRefreshTicker(
            interval: 60,
            schedule: scheduler.schedule,
            isFetching: { [unowned self] in self.fetching },
            refresh: { [unowned self] in self.fetches += 1 }
        )
    }

    func testRefreshesAtTheIntervalWhileVisible() {
        ticker.setVisible(true)
        scheduler.advance(59.999)
        XCTAssertEqual(fetches, 0)
        scheduler.advance(0.001)
        XCTAssertEqual(fetches, 1)
        scheduler.advance(120)
        XCTAssertEqual(fetches, 3)
    }

    func testStopsWhenHiddenAndResumesWhenVisible() {
        ticker.setVisible(true)
        scheduler.advance(60)
        XCTAssertEqual(fetches, 1)

        ticker.setVisible(false)
        scheduler.advance(600)
        XCTAssertEqual(fetches, 1)

        ticker.setVisible(true)
        scheduler.advance(60)
        XCTAssertEqual(fetches, 2)
    }

    func testVisibleTwiceDoesNotDoubleTheRate() {
        ticker.setVisible(true)
        ticker.setVisible(true)
        scheduler.advance(60)
        XCTAssertEqual(fetches, 1)
    }

    func testSkipsATickWhileAFetchIsInFlight() {
        ticker.setVisible(true)
        fetching = true
        scheduler.advance(120)
        XCTAssertEqual(fetches, 0)

        fetching = false
        scheduler.advance(60)
        XCTAssertEqual(fetches, 1)
    }
}
