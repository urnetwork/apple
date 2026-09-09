//
//  WidgetRefreshPolicyTests.swift
//  networkTests
//
//  The widget refresh cadences, which until now were three numbers in three
//  files with no assertion on any of them.
//
//  Two of these encode decisions that are invisible at the call site and were
//  each wrong in the shipped code: a timeline has to carry enough entries to
//  reach its own policy date (four entries five minutes apart did not cover a
//  twenty-minute policy), and the extension's backstop has to be SLOWER than
//  the timeline policy or the two become competing clocks, which is how the
//  widgets ended up asking for ~96 reloads a day against a budget of 40-70
//  and refreshing less often than either number alone would have given.
//

import Testing
import Foundation
@testable import URnetwork

struct WidgetRefreshPolicyTests {

    /// A day's worth of routine requests for one widget instance.
    private func requestsPerDay(_ interval: TimeInterval) -> Double {
        (24 * 60 * 60) / interval
    }

    @Test func entriesReachThePolicyDate() {
        let interval = WidgetRefreshPolicy.refreshIntervalWhileUp
        let count = WidgetRefreshPolicy.entryCount(covering: interval)
        // entries run 0, spacing, 2*spacing ... and the last one must land on
        // (or past) the moment the next timeline is asked for, or the widget
        // holds one render for the remainder of every cycle
        let lastEntryOffset = Double(count - 1) * WidgetRefreshPolicy.entrySpacing
        #expect(interval <= lastEntryOffset + WidgetRefreshPolicy.entrySpacing)
        #expect(lastEntryOffset <= interval)
    }

    /// The hour-long down policy is capped rather than covered: nothing on
    /// screen is a function of the entry's date once the tunnel is down, and
    /// every entry costs an archived render.
    @Test func entriesAreCapped() {
        let count = WidgetRefreshPolicy.entryCount(covering: WidgetRefreshPolicy.refreshIntervalWhileDown)
        #expect(count == WidgetRefreshPolicy.maxEntryCount)
        #expect(WidgetRefreshPolicy.entryCount(covering: WidgetRefreshPolicy.refreshIntervalWhileUp)
            <= WidgetRefreshPolicy.maxEntryCount)
    }

    /// The band the code's own comments cite for one widget instance. The
    /// shipped 20-minute policy was 72 a day and failed this.
    @Test func routineRequestsStayInsideTheBudget() {
        let perDay = requestsPerDay(WidgetRefreshPolicy.refreshIntervalWhileUp)
        #expect(40 <= perDay)
        #expect(perDay <= 70)
    }

    /// A backstop, not a second clock. If the extension asks faster than the
    /// timeline policy it pre-empts it, spends the same budget and gains
    /// nothing, because every reload re-arms the timeline's `.after(...)`.
    @Test func theExtensionBackstopIsSlowerThanTheTimelinePolicy() {
        #expect(WidgetRefreshPolicy.refreshIntervalWhileUp < WidgetRefreshPolicy.extensionBackstopInterval)
    }

    /// WidgetKit's expected entry spacing: the one constant here that is not
    /// free to lower.
    @Test func entrySpacingIsAtLeastFiveMinutes() {
        #expect(5 * 60 <= WidgetRefreshPolicy.entrySpacing)
    }

    @Test func entryCountIsNeverZero() {
        #expect(1 <= WidgetRefreshPolicy.entryCount(covering: 0))
        #expect(1 <= WidgetRefreshPolicy.entryCount(covering: 1))
    }
}
