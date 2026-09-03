//
//  IpFamilyStateTests.swift
//  networkTests
//
//  Covers the write path behind the "Control connections" row: that a tap is
//  never silently lost to a second tap landing inside the read-back, and that
//  the in-flight guard always reopens afterwards.
//
//  Driven through the no-device / no-space fallback, which is the
//  process-global setter -- so this needs neither a device, a tunnel, nor the
//  simulator ui. That global is shared across the test process, hence
//  `.serialized` and an explicit reset in every test.
//
//  The rounds are not padding. Which suspensions actually hand the main actor
//  over is the runtime's business, so a single pass can miss the read-back
//  window and prove nothing; the test therefore requires that at least one
//  round genuinely caught the cycle mid-flight.
//
//  What is asserted is the GUARD, not the end state, because the end state
//  cannot tell the two behaviours apart: a second tap that is correctly
//  refused and a second tap that is accepted-but-lost both leave the policy on
//  Force IPv4, since the lost one recomputes `next` from the same pre-refresh
//  Automatic and writes Force IPv4 a second time. The observable difference is
//  that the lost one was admitted at all -- an extra write, which with a
//  device is a real rpc into the extension -- so that is what is measured
//  here. (Checked: a test asserting only the final policy passes against the
//  defect, so it is not written.)
//

import Testing
import URnetworkSdk
@testable import URnetwork

/// Set by the cycling task the instant `cycle` returns, so an observing loop
/// can tell "still in flight" from "finished" without a timeout.
@MainActor
private final class CycleCompletion {
    var finished = false
}

private let rounds = 8

@Suite(.serialized)
@MainActor
struct IpFamilyStateTests {

    /// A fresh state reading Automatic, with the process global it writes to
    /// reset to match.
    private func automaticState() async -> IpFamilyState {
        SdkSetControlIpFamilyPolicy(IpFamily.auto)
        let state = IpFamilyState()
        await state.refresh(device: nil)
        return state
    }

    /**
     * The in-flight guard must stay closed for the WHOLE of `cycle` -- the
     * write and the read-back as one unit.
     *
     * `cycle` suspends twice, once on the write and once inside `refresh`, and
     * both suspensions free the main actor. A second tap queued behind the
     * first runs at exactly those points. If the guard has already reopened by
     * the second one, that tap computes `IpFamily.next(policy)` from the
     * pre-refresh policy the first tap already superseded, writes the same
     * value back, and is lost: auto -> force4, tap again -> force4.
     *
     * So this observes `isApplying` from the main actor at every scheduling
     * point the in-flight cycle yields -- the same points a queued tap would
     * get -- and requires it true at all of them.
     */
    @Test func inFlightGuardStaysClosedAcrossTheReadBack() async {
        var roundsThatCaughtItInFlight = 0

        for _ in 0..<rounds {
            let state = await automaticState()
            let completion = CycleCompletion()

            let cycling = Task { @MainActor in
                await state.cycle(device: nil, networkSpace: nil)
                completion.finished = true
            }

            var sawInFlight = false
            var guardReopenedEarly = false
            while !completion.finished {
                if state.isApplying {
                    sawInFlight = true
                } else if sawInFlight {
                    // `cycle` has not returned yet, but the guard is open: a
                    // tap arriving here would be accepted and then lost
                    guardReopenedEarly = true
                }
                await Task.yield()
            }
            await cycling.value

            #expect(!guardReopenedEarly)
            #expect(state.policy == IpFamily.force4)
            if sawInFlight {
                roundsThatCaughtItInFlight += 1
            }
        }

        // the observation loop has to have actually run while a cycle was in
        // flight, or the round above proved nothing
        #expect(0 < roundsThatCaughtItInFlight)
    }

    /**
     * The other half of the same guard: it must always reopen. A stuck
     * `isApplying` wedges the row permanently, which is worse than the lost
     * tap the guard exists to prevent.
     */
    @Test func guardReopensAfterEveryTap() async {
        let state = await automaticState()

        await state.cycle(device: nil, networkSpace: nil)
        #expect(!state.isApplying)

        await state.cycle(device: nil, networkSpace: nil)
        #expect(!state.isApplying)

        SdkSetControlIpFamilyPolicy(IpFamily.auto)
    }

    /**
     * Sequential taps advance one step each, read back from the sdk rather
     * than assumed -- the whole point of the row.
     */
    @Test func sequentialTapsAdvanceOneStepEach() async {
        let state = await automaticState()
        #expect(state.policy == IpFamily.auto)

        await state.cycle(device: nil, networkSpace: nil)
        #expect(state.policy == IpFamily.force4)

        await state.cycle(device: nil, networkSpace: nil)
        #expect(state.policy == IpFamily.force6)

        await state.cycle(device: nil, networkSpace: nil)
        #expect(state.policy == IpFamily.auto)
    }
}
