//
//  TransportDelayFormatTests.swift
//  networkTests
//

import Testing
@testable import URnetwork

/**
 * The slow internet indicator's numbers (apple/DELAY.md §4): the units are
 * the same on every platform and not localized, and a 0 value has no text,
 * so its line hides.
 */
struct TransportDelayFormatTests {

    // under a second: whole milliseconds
    @Test func aDelayUnderASecondIsWholeMilliseconds() {
        #expect(TransportDelayFormat.delay(millis: 1) == "1 ms")
        #expect(TransportDelayFormat.delay(millis: 640) == "640 ms")
        #expect(TransportDelayFormat.delay(millis: 999) == "999 ms")
    }

    // from a second: one decimal, then whole seconds from ten
    @Test func aDelayFromASecondIsSeconds() {
        #expect(TransportDelayFormat.delay(millis: 1000) == "1.0 s")
        #expect(TransportDelayFormat.delay(millis: 1200) == "1.2 s")
        #expect(TransportDelayFormat.delay(millis: 1249) == "1.2 s")
        #expect(TransportDelayFormat.delay(millis: 1250) == "1.3 s")
        #expect(TransportDelayFormat.delay(millis: 9949) == "9.9 s")
        // rounds to ten seconds: whole seconds, never "10.0 s"
        #expect(TransportDelayFormat.delay(millis: 9950) == "10 s")
        #expect(TransportDelayFormat.delay(millis: 12_000) == "12 s")
        #expect(TransportDelayFormat.delay(millis: 12_499) == "12 s")
        #expect(TransportDelayFormat.delay(millis: 125_000) == "125 s")
    }

    @Test func noDelayHasNoText() {
        #expect(TransportDelayFormat.delay(millis: 0) == nil)
        #expect(TransportDelayFormat.delay(millis: -5) == nil)
    }

    // under a megabit: whole kilobits, at least 1
    @Test func aRateUnderAMegabitIsWholeKilobits() {
        #expect(TransportDelayFormat.rate(bitsPerSecond: 1) == "1 kb/s")
        #expect(TransportDelayFormat.rate(bitsPerSecond: 499) == "1 kb/s")
        #expect(TransportDelayFormat.rate(bitsPerSecond: 48_000) == "48 kb/s")
        #expect(TransportDelayFormat.rate(bitsPerSecond: 85_400) == "85 kb/s")
        #expect(TransportDelayFormat.rate(bitsPerSecond: 999_499) == "999 kb/s")
    }

    // from a megabit: one decimal; a rate that rounds to a thousand kilobits
    // reads as megabits, never "1000 kb/s"
    @Test func aRateFromAMegabitIsMegabits() {
        #expect(TransportDelayFormat.rate(bitsPerSecond: 999_600) == "1.0 Mb/s")
        #expect(TransportDelayFormat.rate(bitsPerSecond: 1_000_000) == "1.0 Mb/s")
        #expect(TransportDelayFormat.rate(bitsPerSecond: 1_400_000) == "1.4 Mb/s")
        #expect(TransportDelayFormat.rate(bitsPerSecond: 1_449_999) == "1.4 Mb/s")
        #expect(TransportDelayFormat.rate(bitsPerSecond: 1_450_000) == "1.5 Mb/s")
        #expect(TransportDelayFormat.rate(bitsPerSecond: 123_400_000) == "123.4 Mb/s")
    }

    @Test func noRateHasNoText() {
        #expect(TransportDelayFormat.rate(bitsPerSecond: 0) == nil)
        #expect(TransportDelayFormat.rate(bitsPerSecond: -1) == nil)
    }

    // the worse direction's number is the amber one: the larger delay
    @Test func theLargerDelayIsTheWorseDirection() {
        #expect(TransportDelayDirection.worse(upDelayMillis: 640, downDelayMillis: 1200) == .down)
        #expect(TransportDelayDirection.worse(upDelayMillis: 2000, downDelayMillis: 300) == .up)
        #expect(TransportDelayDirection.worse(upDelayMillis: 500, downDelayMillis: 500) == nil)
        #expect(TransportDelayDirection.worse(upDelayMillis: 0, downDelayMillis: 0) == nil)
    }
}
