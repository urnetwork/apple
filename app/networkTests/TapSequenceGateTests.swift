import Foundation
import Testing
@testable import URnetwork

struct TapSequenceGateTests {

    private let start = Date(timeIntervalSince1970: 1_000_000)

    @Test func fiveTapsWithinTheWindowComplete() {
        var gate = TapSequenceGate(count: 5, window: 2)
        for i in 0..<4 {
            #expect(!gate.register(at: start.addingTimeInterval(Double(i) * 0.5)))
        }
        #expect(gate.register(at: start.addingTimeInterval(2)))
    }

    @Test func aGapOverTwoSecondsStartsOver() {
        var gate = TapSequenceGate(count: 5, window: 2)
        for i in 0..<4 {
            #expect(!gate.register(at: start.addingTimeInterval(Double(i) * 0.5)))
        }
        #expect(gate.taps == 4)
        // the fifth tap comes 2.1 s after the fourth: it is the first of a new run
        #expect(!gate.register(at: start.addingTimeInterval(1.5 + 2.1)))
        #expect(gate.taps == 1)
        for i in 1..<4 {
            #expect(!gate.register(at: start.addingTimeInterval(3.6 + Double(i) * 0.5)))
        }
        #expect(gate.register(at: start.addingTimeInterval(3.6 + 2)))
    }

    @Test func aGapOfExactlyTwoSecondsStillCounts() {
        var gate = TapSequenceGate(count: 5, window: 2)
        for i in 0..<4 {
            #expect(!gate.register(at: start.addingTimeInterval(Double(i) * 2)))
        }
        #expect(gate.register(at: start.addingTimeInterval(8)))
    }

    @Test func aCompletedSequenceNeedsTheFullCountAgain() {
        var gate = TapSequenceGate(count: 5, window: 2)
        for i in 0..<5 {
            _ = gate.register(at: start.addingTimeInterval(Double(i) * 0.3))
        }
        #expect(gate.taps == 0)
        for i in 5..<9 {
            #expect(!gate.register(at: start.addingTimeInterval(Double(i) * 0.3)))
        }
        #expect(gate.register(at: start.addingTimeInterval(9 * 0.3)))
    }
}
