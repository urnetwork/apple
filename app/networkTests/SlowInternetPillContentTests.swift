//
//  SlowInternetPillContentTests.swift
//  networkTests
//

import Testing
@testable import URnetwork

/**
 * What the connect screen's slow internet pill says (apple/DELAY.md §5.2):
 * "Poor signal", or "Fallback" on the fallback connection; each direction's
 * standing delay, else its limited rate, else nothing; the larger delay the
 * worse, drawn amber; with too little room the better direction goes, then
 * the numbers; and "Internet back to normal" on a return to normal, never
 * when the reading only went away.
 */
struct SlowInternetPillContentTests {

    typealias Content = SlowInternetPillContent

    private static let slow = TransportDelayReading(
        upQuality: 0.25,
        downQuality: 0.75,
        upBitsPerSecond: 48_000,
        downBitsPerSecond: 85_000,
        upDelayMillis: 800,
        downDelayMillis: 1900
    )

    /// No standing delay either way, both directions limited.
    private static let ratesOnly = TransportDelayReading(
        downQuality: 0.75,
        upBitsPerSecond: 150_000,
        downBitsPerSecond: 280_000
    )

    /// The store's state with `reading`, linked to the extension.
    private static func live(_ reading: TransportDelayReading) -> TransportDelayState {
        TransportDelayState(reading: reading, available: true)
    }

    @Test func theLabelIsPoorSignalOrFallback() {
        #expect(Content(reading: Self.slow).label == .poorSignal)
        var fallback = Self.slow
        fallback.fallback = true
        #expect(Content(reading: fallback).label == .fallback)
    }

    // each direction shows its standing delay, the larger one the worse
    @Test func eachDirectionShowsItsDelay() {
        let content = Content(reading: Self.slow)
        #expect(content.up == "800 ms")
        #expect(content.down == "1.9 s")
        #expect(content.worse == .down)
        #expect(!content.recovered)

        var upWorse = Self.slow
        upWorse.upDelayMillis = 2900
        #expect(Content(reading: upWorse).worse == .up)

        // equal delays mark neither
        var equal = Self.slow
        equal.upDelayMillis = 1900
        #expect(Content(reading: equal).worse == nil)
    }

    // no standing delay but a limited rate: the rate shows instead, and a
    // rate is never the worse, which goes by delay
    @Test func aDirectionWithNoDelayShowsItsLimitedRate() {
        let mixed = Content(reading: TransportDelayReading(
            upQuality: 0.5,
            upBitsPerSecond: 150_000,
            downBitsPerSecond: 280_000,
            downDelayMillis: 620
        ))
        #expect(mixed.up == "150 kb/s")
        #expect(mixed.down == "620 ms")
        #expect(mixed.worse == .down)

        let rates = Content(reading: Self.ratesOnly)
        #expect(rates.up == "150 kb/s")
        #expect(rates.down == "280 kb/s")
        #expect(rates.worse == nil)
    }

    // neither a delay nor a rate: the direction hides; with both hidden the
    // pill is the tunnel and the label
    @Test func aDirectionWithNeitherHides() {
        let downOnly = Content(reading: TransportDelayReading(downQuality: 0.25, downDelayMillis: 640))
        #expect(downOnly.up == nil)
        #expect(downOnly.down == "640 ms")
        #expect(downOnly.worse == .down)

        let neither = Content(reading: TransportDelayReading(upQuality: 0.5))
        #expect(neither.up == nil)
        #expect(neither.down == nil)
        #expect(neither.worse == nil)
        #expect(neither.label == .poorSignal)
    }

    // with too little room the better direction goes first, then the numbers
    @Test func theBetterDirectionGoesFirstThenTheNumbers() {
        let content = Content(reading: Self.slow)
        let one = content.worseOnly
        #expect(one.up == nil)
        #expect(one.down == "1.9 s")
        #expect(one.label == .poorSignal)
        let none = content.labelOnly
        #expect(none.up == nil)
        #expect(none.down == nil)
        #expect(none.label == .poorSignal)

        var upWorse = Self.slow
        upWorse.upDelayMillis = 2900
        #expect(Content(reading: upWorse).worseOnly.up == "2.9 s")
        #expect(Content(reading: upWorse).worseOnly.down == nil)

        // neither worse: the download stays, or the upload when only it shows
        let rates = Content(reading: Self.ratesOnly).worseOnly
        #expect(rates.up == nil)
        #expect(rates.down == "280 kb/s")
        let upOnly = Content(reading: TransportDelayReading(upQuality: 0.5, upBitsPerSecond: 150_000))
        #expect(upOnly.worseOnly == upOnly)
    }

    // the reading returns to normal while the pill shows it: "Internet back
    // to normal" with no numbers, which then holds
    @Test func aReturnToNormalShowsTheRecoveredState() throws {
        let slow = try #require(Content.next(after: nil, state: Self.live(Self.slow), hidden: false))
        #expect(slow == Content(reading: Self.slow))

        let recovered = try #require(Content.next(after: slow, state: Self.live(.normal), hidden: false))
        #expect(recovered.recovered)
        #expect(recovered.up == nil)
        #expect(recovered.down == nil)
        #expect(recovered.worse == nil)

        // later normal readings, numbers under the thresholds included, hold it
        #expect(Content.next(after: recovered, state: Self.live(.normal), hidden: false) == recovered)
        let quiet = TransportDelayReading(upDelayMillis: 120, downDelayMillis: 90)
        #expect(Content.next(after: recovered, state: Self.live(quiet), hidden: false) == recovered)
        #expect(Content.next(after: slow, state: Self.live(quiet), hidden: false) == recovered)
    }

    // a new slow level during the hold ends it: the slow content returns
    @Test func aSlowLevelDuringTheHoldReturnsToTheSlowContent() throws {
        let slow = Content(reading: Self.slow)
        let recovered = try #require(Content.next(after: slow, state: Self.live(.normal), hidden: false))
        var again = Self.slow
        again.downDelayMillis = 2400
        let next = try #require(Content.next(after: recovered, state: Self.live(again), hidden: false))
        #expect(!next.recovered)
        #expect(next == Content(reading: again))
    }

    // the reading going away (a reset, the device remote unlinked) or the
    // can't-reach banner taking the top is no recovery: the pill just leaves
    @Test func aReadingThatGoesAwayIsNoRecovery() {
        let slow = Content(reading: Self.slow)
        #expect(Content.next(after: slow, state: TransportDelayState(), hidden: false) == nil)
        #expect(Content.next(after: slow, state: TransportDelayState(reading: Self.slow, available: false), hidden: false) == nil)
        #expect(Content.next(after: slow, state: Self.live(Self.slow), hidden: true) == nil)
        #expect(Content.next(after: slow, state: Self.live(.normal), hidden: true) == nil)

        // the banner during the hold ends it at once
        let recovered = Content.next(after: slow, state: Self.live(.normal), hidden: false)
        #expect(recovered?.recovered == true)
        #expect(Content.next(after: recovered, state: Self.live(.normal), hidden: true) == nil)
    }

    // nothing shown, a normal reading shows nothing: no recovered state
    // without a slow spell on screen (the pill appearing, or one that left)
    @Test func normalWithNothingShownShowsNothing() {
        #expect(Content.next(after: nil, state: Self.live(.normal), hidden: false) == nil)
        #expect(Content.next(after: nil, state: TransportDelayState(), hidden: false) == nil)
    }
}
