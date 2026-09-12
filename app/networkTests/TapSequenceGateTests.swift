import Foundation
import Testing
@testable import URnetwork

// `#expect` evaluates its operands by value, so a mutating call such as
// `gate.register(at:)` cannot appear inside it with the Xcode 26 toolchain
// ("cannot use mutating member on immutable value"). Each tap is registered on
// its own line and only its result is asserted; the assertions are unchanged.
struct TapSequenceGateTests {

    private let start = Date(timeIntervalSince1970: 1_000_000)

    @Test func fiveTapsWithinTheWindowComplete() {
        var gate = TapSequenceGate(count: 5, window: 2)
        for i in 0..<4 {
            let completed = gate.register(at: start.addingTimeInterval(Double(i) * 0.5))
            #expect(!completed)
        }
        let completed = gate.register(at: start.addingTimeInterval(2))
        #expect(completed)
    }

    @Test func aGapOverTwoSecondsStartsOver() {
        var gate = TapSequenceGate(count: 5, window: 2)
        for i in 0..<4 {
            let completed = gate.register(at: start.addingTimeInterval(Double(i) * 0.5))
            #expect(!completed)
        }
        #expect(gate.taps == 4)
        // the fifth tap comes 2.1 s after the fourth: it is the first of a new run
        let restarted = gate.register(at: start.addingTimeInterval(1.5 + 2.1))
        #expect(!restarted)
        #expect(gate.taps == 1)
        for i in 1..<4 {
            let completed = gate.register(at: start.addingTimeInterval(3.6 + Double(i) * 0.5))
            #expect(!completed)
        }
        let completed = gate.register(at: start.addingTimeInterval(3.6 + 2))
        #expect(completed)
    }

    @Test func aGapOfExactlyTwoSecondsStillCounts() {
        var gate = TapSequenceGate(count: 5, window: 2)
        for i in 0..<4 {
            let completed = gate.register(at: start.addingTimeInterval(Double(i) * 2))
            #expect(!completed)
        }
        let completed = gate.register(at: start.addingTimeInterval(8))
        #expect(completed)
    }

    @Test func aCompletedSequenceNeedsTheFullCountAgain() {
        var gate = TapSequenceGate(count: 5, window: 2)
        for i in 0..<5 {
            _ = gate.register(at: start.addingTimeInterval(Double(i) * 0.3))
        }
        #expect(gate.taps == 0)
        for i in 5..<9 {
            let completed = gate.register(at: start.addingTimeInterval(Double(i) * 0.3))
            #expect(!completed)
        }
        let completed = gate.register(at: start.addingTimeInterval(9 * 0.3))
        #expect(completed)
    }
}
