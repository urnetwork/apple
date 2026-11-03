#if os(macOS)
import AppKit
import Foundation
import Testing
@testable import URnetwork

/// The alert before a purchase drops the connection, run for real: each test
/// presses a button from inside the alert's modal loop, which is the only place
/// a timer on its mode can fire, so nothing here waits on time. It shows on the
/// screen for as long as that takes.
@MainActor
@Suite(.serialized)
struct PurchaseDisconnectNoticeTests {

    /// Runs `block` in the alert's modal loop, `delay` from when it starts.
    private static func inTheModalLoop(after delay: TimeInterval = 0, _ block: @escaping @MainActor () -> Void) -> Timer {
        let timer = Timer(timeInterval: delay, repeats: false) { _ in
            MainActor.assumeIsolated {
                block()
            }
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        return timer
    }

    private static func answer(pressing button: Int) async -> Bool {
        let alert = PurchaseDisconnectNotice.makeAlert()
        _ = inTheModalLoop {
            alert.buttons[button].performClick(nil)
        }
        return await PurchaseDisconnectNotice.answer(alert)
    }

    @Test func theFirstButtonGoesAheadAndTheOtherDoesNot() async {
        #expect(await Self.answer(pressing: 0))
        #expect(await !Self.answer(pressing: 1))
    }

    /// The flow asks on the main actor and waits there. Status reports and the
    /// menu bar run on it too: they go on while the alert is up.
    @Test func theMainActorKeepsRunningWhileTheAlertIsUp() async {
        final class Ran: @unchecked Sendable {
            var value = false
        }
        let alert = PurchaseDisconnectNotice.makeAlert()
        let ran = Ran()
        _ = Self.inTheModalLoop {
            Task { @MainActor in
                ran.value = true
                alert.buttons[1].performClick(nil)
            }
        }
        // ends the alert if that task never runs, so the test fails rather than
        // waiting with an alert on the screen
        let bound = Self.inTheModalLoop(after: 10) {
            alert.buttons[1].performClick(nil)
        }
        defer {
            bound.invalidate()
        }
        #expect(await !PurchaseDisconnectNotice.answer(alert))
        #expect(ran.value)
    }

    @Test func theFirstButtonDisconnectsAndTheOtherCancels() {
        let alert = PurchaseDisconnectNotice.makeAlert()
        #expect(alert.buttons.map(\.title) == [String(localized: "Disconnect"), String(localized: "Cancel")])
        #expect(alert.buttons.last?.keyEquivalent == "\u{1b}")
    }

    @Test func itSaysWhatHappensToTheConnectionAndTheTraffic() {
        let alert = PurchaseDisconnectNotice.makeAlert()
        #expect(alert.messageText == String(localized: "Disconnect the VPN for this purchase?"))
        #expect(alert.informativeText == String(localized: "URnetwork reconnects it afterward. Until it does, your internet traffic won't go through the VPN."))
    }
}
#endif
