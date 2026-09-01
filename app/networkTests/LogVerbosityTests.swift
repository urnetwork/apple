//
//  LogVerbosityTests.swift
//  networkTests
//
//  Covers the vocabulary of the log-detail control: what each level is called,
//  what it promises, which levels put the destinations of real traffic into
//  the logs, that an out-of-range level can neither be offered nor crash the
//  mapping, and that "no device to ask" stays distinct from "level 0".
//
//  That last one is the part that can be wrong with nothing failing. The SDK
//  setter throws nothing, clamps silently and can be refused outright, and the
//  logs are written by the packet tunnel extension rather than this process --
//  so the row's honesty rests entirely on how a level READ BACK from the
//  device is interpreted here. Mirrors android's LogVerbosityTest.
//

import Testing
import Foundation
@testable import URnetwork

struct LogVerbosityTests {

    @Test func levelsAreNamedForWhatTheyBuy() {
        #expect(LogVerbosity.name(0) == "Default")
        #expect(LogVerbosity.name(1) == "Verbose")
        #expect(LogVerbosity.name(2) == "Trace")

        // the detail line has to name what is gained, not just say "more" --
        // it is what the choice is made on, before the reproduction
        #expect(LogVerbosity.detail(0).contains("contract pings"))
        #expect(LogVerbosity.detail(1).contains("Contract accounting"))
        #expect(LogVerbosity.detail(1).contains("block decisions"))
        #expect(LogVerbosity.detail(2).contains("Transport and window internals"))

        // ... and what it costs
        #expect(LogVerbosity.detail(1).contains("destination IP addresses"))
        #expect(LogVerbosity.detail(2).contains("Very large logs"))
    }

    /// The number is what the SDK reports and what a support thread compares;
    /// the name is what the row means. Both are shown.
    @Test func theValueLabelReportsTheLevelTheDeviceGave() {
        #expect(LogVerbosity.valueLabel(0) == "0 · Default")
        #expect(LogVerbosity.valueLabel(1) == "1 · Verbose")
        #expect(LogVerbosity.valueLabel(2) == "2 · Trace")

        // a level an embedder set past the range is reported as the number it
        // actually is, rather than being quietly redrawn as 2 -- the control
        // is the only place the discrepancy could show
        #expect(LogVerbosity.valueLabel(7) == "7 · Trace")
    }

    /**
     * The clamp is what keeps an out-of-range level from indexing past the
     * labels, and it mirrors the SDK's own clamp so the control never offers
     * a level that would come back changed.
     */
    @Test func levelsClampToWhatTheSdkHonors() {
        #expect(LogVerbosity.clamp(0) == 0)
        #expect(LogVerbosity.clamp(1) == 1)
        #expect(LogVerbosity.clamp(2) == 2)

        #expect(LogVerbosity.clamp(3) == 2)
        #expect(LogVerbosity.clamp(Int.max) == 2)
        #expect(LogVerbosity.clamp(-1) == 0)
        #expect(LogVerbosity.clamp(Int.min) == 0)

        // out of range must still map to a label rather than trapping
        #expect(LogVerbosity.name(-1) == "Default")
        #expect(LogVerbosity.name(9) == "Trace")

        #expect(LogVerbosity.range == 0...2)
    }

    /**
     * The privacy line. V(1) is where the per-packet block decisions and the
     * contract accounting start naming addresses, so the warning has to
     * appear at 1 -- not only at the loudest level.
     */
    @Test func raisedLevelsAreMarkedAsRevealingDestinations() {
        #expect(LogVerbosity.revealsDestinations(0) == false)
        #expect(LogVerbosity.revealsDestinations(1) == true)
        #expect(LogVerbosity.revealsDestinations(2) == true)

        // an out-of-range level logs strictly more, never less
        #expect(LogVerbosity.revealsDestinations(9) == true)

        // a nonsensical negative level is not a reason to warn
        #expect(LogVerbosity.revealsDestinations(-1) == false)
    }

    /**
     * "There is no device to ask" and "the device is at level 0" are
     * different claims, and reporting the second for the first is the local
     * guess this control exists to avoid: the contract and transport logging
     * is produced by the packet tunnel extension, so with nothing read back
     * the level in force there is unknown -- it may be anything, or the
     * extension may never have received the setting at all.
     *
     * Matches android's LogVerbosityTest.aLevelWithNoDeviceIsUnknownRatherThanDefault.
     */
    @Test func noDeviceReadsAsUnavailableRatherThanLevelZero() {
        #expect(LogVerbosity.valueLabel(nil) == "Unavailable")
        #expect(LogVerbosity.valueLabel(nil) != LogVerbosity.valueLabel(0))
        // ... and level 0, which WAS read back, still reports itself
        #expect(LogVerbosity.valueLabel(0) == "0 · Default")

        #expect(LogVerbosity.name(nil) == LogVerbosity.unavailableLabel)
        #expect(LogVerbosity.name(nil) != LogVerbosity.name(0))

        // the row keeps a detail line in the unavailable state: it says why
        // there is no level rather than describing one that is not in force
        #expect(LogVerbosity.detail(nil) == LogVerbosity.unavailableDetail)
        #expect(LogVerbosity.detail(nil) != LogVerbosity.detail(0))
        #expect(LogVerbosity.detail(nil).contains("no device"))
    }

    /**
     * The warning is a claim about what IS being written. With no device
     * nothing was read back, so there is no claim to make in either
     * direction -- asserting one would be as much of a guess as reporting
     * level 0.
     *
     * Matches android's LogVerbosityTest.noWarningIsClaimedForALevelThatWasNeverReadBack.
     */
    @Test func noWarningIsClaimedForALevelThatWasNeverReadBack() {
        #expect(LogVerbosity.revealsDestinations(nil) == false)
    }

    /**
     * The state's half of the same invariant: with no device the published
     * level is cleared rather than left at a local default, and rather than
     * left standing from a device that is now gone.
     *
     * `refresh` used to return early on a nil device, so the row rendered the
     * initial `LogVerbosity.minimum` -- a confident "0 · Default" for a level
     * nobody had asked about.
     */
    @Test @MainActor func theStateHasNoLevelWithoutADeviceToReadOne() async {
        let state = LogVerbosityState()
        #expect(state.level == nil)

        await state.refresh(device: nil)
        #expect(state.level == nil)

        // a write with no device has nothing to read back either, so it must
        // not leave a level behind: it is the requested value, unconfirmed
        await state.setLevel(LogVerbosity.maximum, device: nil)
        #expect(state.level == nil)
    }

    /// The warning has to say what is in the logs AND what to do about it:
    /// the redacted export is the whole reason a raised level is still safe
    /// to share from.
    @Test func theWarningNamesBothTheExposureAndTheWayOut() {
        let warning = LogVerbosity.destinationWarning
        #expect(warning.contains("destination addresses"))
        #expect(warning.contains("ports"))
        #expect(warning.contains("redacted"))
    }
}
