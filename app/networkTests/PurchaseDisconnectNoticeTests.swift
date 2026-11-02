#if os(macOS)
import AppKit
import Foundation
import Testing
@testable import URnetwork

/// The alert before a purchase drops the connection. Running it needs a person,
/// so this holds what the flow relies on: the first button is the one that goes
/// ahead, and Escape cancels.
@MainActor
struct PurchaseDisconnectNoticeTests {

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
