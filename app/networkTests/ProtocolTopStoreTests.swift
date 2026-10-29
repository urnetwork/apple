//
//  ProtocolTopStoreTests.swift
//  networkTests
//

import Foundation
import Testing
@testable import URnetwork

/**
 * The Protocol leaderboard's store (LEADERTOP, owner decision 2026-10-29)
 * over a fake client: the loads its lifecycle starts, paging over the
 * cursor to the top 400, a failed page parking the list, seeks that load
 * through to their row, the tab reset, the card's states, a refresh that
 * fails keeping the rows, and that only the newest load lands. The client
 * answers when a test says, the answers' hops to the main queue go to a
 * queue the test drains, and the clock is the test's, so nothing waits,
 * polls or reads a real clock.
 */
@MainActor
struct ProtocolTopStoreTests {

    private typealias PageDone = (Result<SnTopPageInfo, SnTopRequestFailed>) -> Void
    private typealias MeDone = (Result<SnTopMeResultInfo, SnTopRequestFailed>) -> Void

    private struct PageRequest: Equatable {
        let limit: Int
        let cursor: String
        let snapshot: String
    }

    /// Records each request and answers it when the test says.
    private final class FakeClient: SnTopClient {
        var pageRequests: [PageRequest] = []
        var pageAnswers: [PageDone] = []
        var meAnswers: [MeDone] = []

        func fetchTop(limit: Int, cursor: String, snapshot: String, _ done: @escaping PageDone) {
            pageRequests.append(PageRequest(limit: limit, cursor: cursor, snapshot: snapshot))
            pageAnswers.append(done)
        }

        func fetchTopMe(_ done: @escaping MeDone) {
            meAnswers.append(done)
        }

        /// Answers the newest page request.
        func answerPage(_ result: Result<SnTopPageInfo, SnTopRequestFailed>) throws {
            let done = try #require(pageAnswers.last)
            done(result)
        }

        /// Answers a page request by its index.
        func answerPage(at index: Int, _ result: Result<SnTopPageInfo, SnTopRequestFailed>) {
            pageAnswers[index](result)
        }

        func answerMe(_ result: Result<SnTopMeResultInfo, SnTopRequestFailed>) throws {
            let done = try #require(meAnswers.last)
            done(result)
        }
    }

    /// The answers' hops to the main queue, run when the test says.
    private final class Hops {
        var pending: [@MainActor () -> Void] = []

        func dispatch(_ work: @escaping @MainActor () -> Void) {
            pending.append(work)
        }

        @MainActor
        func drain() {
            while !pending.isEmpty {
                let work = pending.removeFirst()
                work()
            }
        }
    }

    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_790_000_000)
    }

    /// A session the store's client belongs to.
    private final class Session {}

    private static func snapshot(_ id: String = "s1", tempo: Int64 = 100, total: Int = 41_230, bindingOpen: Bool = false) -> SnTopSnapshotInfo {
        SnTopSnapshotInfo(id: id, tempoIndex: tempo, totalRanked: total, projectedCutoff: 41.2, bindingOpen: bindingOpen)
    }

    private static func rows(_ positions: ClosedRange<Int>) -> [SnTopRowInfo] {
        positions.map { SnTopRowInfo(position: $0, projectedScore: Double(500 - $0)) }
    }

    private static func page(_ positions: ClosedRange<Int>, next: String?, snapshot: SnTopSnapshotInfo? = nil, me: SnTopRowInfo? = nil) -> SnTopPageInfo {
        SnTopPageInfo(snapshot: snapshot ?? Self.snapshot(), rows: rows(positions), me: me, next: next)
    }

    private static let myRow = SnTopRowInfo(position: 173, margin: 0.12, claimPrompt: true, isMe: true)

    private static func meResult(position: Int = 173) -> SnTopMeResultInfo {
        SnTopMeResultInfo(
            snapshot: snapshot(),
            me: SnTopMeInfo(row: SnTopRowInfo(position: position, isMe: true), soloScore: 21.4, distinctPrefixes: 18, sharedPrefixes: 3)
        )
    }

    private struct Harness {
        let client: FakeClient
        let hops: Hops
        let clock: Clock
        let session: Session
        let store: ProtocolTopStore
    }

    /// A store on screen and presenting, with its first page and card asked for.
    private func visibleStore(signedIn: Bool = true) -> Harness {
        let client = FakeClient()
        let hops = Hops()
        let clock = Clock()
        let session = Session()
        let store = ProtocolTopStore(dispatch: { hops.dispatch($0) }, now: { clock.now })
        store.setSignedIn(signedIn)
        store.setClient(client, session: session)
        store.setPresentationActive(true)
        store.setOnScreen(true)
        return Harness(client: client, hops: hops, clock: clock, session: session, store: store)
    }

    // MARK: loads

    @Test func nothingLoadsUntilTheTabIsVisible() {
        let client = FakeClient()
        let session = Session()
        let store = ProtocolTopStore(dispatch: { _ in }, now: { Date() })
        store.setClient(client, session: session)
        store.setOnScreen(true)
        #expect(client.pageRequests.isEmpty)
        #expect(client.meAnswers.isEmpty)
        store.setPresentationActive(true)
        // the first page of the newest snapshot, 50 rows, and the card
        #expect(client.pageRequests == [PageRequest(limit: 50, cursor: "", snapshot: "")])
        #expect(client.meAnswers.count == 1)
    }

    @Test func theFirstPageLandsWithPlaceholdersUntilThen() throws {
        let h = visibleStore()
        #expect(h.store.state.listContent == .loading)
        #expect(h.store.state.cardContent == .loading)

        try h.client.answerPage(.success(Self.page(1...50, next: "c50", me: Self.myRow)))
        // nothing lands before its hop to the main queue
        #expect(h.store.state.listContent == .loading)
        h.hops.drain()

        #expect(h.store.state.listContent == .list)
        #expect(h.store.state.rows.map(\.position) == Array(1...50))
        #expect(h.store.state.next == "c50")
        #expect(h.store.state.meRow == Self.myRow)
        #expect(h.store.state.hasMore)
        #expect(h.store.state.trackTotal == 400)
    }

    @Test func anEmptySnapshotSaysSo() throws {
        let h = visibleStore()
        try h.client.answerPage(.success(SnTopPageInfo(snapshot: Self.snapshot(total: 0), rows: [], next: nil)))
        h.hops.drain()
        #expect(h.store.state.listContent == .empty)
        #expect(!h.store.state.hasMore)
    }

    @Test func aFailedFirstPageShowsTheRetryRowAndRetryAsksAgain() throws {
        let h = visibleStore()
        try h.client.answerPage(.failure(SnTopRequestFailed()))
        h.hops.drain()
        #expect(h.store.state.listContent == .failed)

        h.store.retryList()
        #expect(h.store.state.listContent == .loading)
        #expect(h.client.pageRequests.count == 2)
        #expect(h.client.pageRequests.last == PageRequest(limit: 50, cursor: "", snapshot: ""))
    }

    // MARK: pages

    @Test func pagesFollowTheCursorFiftyAtATimeToTheEndOfTheBoard() throws {
        let h = visibleStore()
        try h.client.answerPage(.success(Self.page(1...50, next: "c50")))
        h.hops.drain()

        h.store.loadMore()
        // the cursor alone pins the page to the list's snapshot
        #expect(h.client.pageRequests.last == PageRequest(limit: 50, cursor: "c50", snapshot: ""))
        // a second ask while the page is in flight sends nothing
        h.store.loadMore()
        #expect(h.client.pageRequests.count == 2)

        try h.client.answerPage(.success(Self.page(51...100, next: "c100")))
        h.hops.drain()
        #expect(h.store.state.rows.map(\.position) == Array(1...100))
        #expect(h.store.state.next == "c100")
    }

    @Test func theBoardEndsAtFourHundredWhateverTheCursorSays() throws {
        let h = visibleStore()
        try h.client.answerPage(.success(Self.page(1...50, next: "c50")))
        h.hops.drain()
        h.store.seek(to: 400)
        // one request reaches as far as the api allows
        #expect(h.client.pageRequests.last?.limit == 200)
        try h.client.answerPage(.success(Self.page(51...250, next: "c250")))
        h.hops.drain()
        // and the next asks only for what is left of the board
        #expect(h.client.pageRequests.last?.limit == 150)
        // rows past 400 are not kept, and the cursor after them is not followed
        try h.client.answerPage(.success(Self.page(251...410, next: "c410")))
        h.hops.drain()
        #expect(h.store.state.lastPosition == 400)
        #expect(h.store.state.next == nil)
        #expect(!h.store.state.hasMore)
        let before = h.client.pageRequests.count
        h.store.loadMore()
        #expect(h.client.pageRequests.count == before)
    }

    @Test func aPageThatAddsNothingEndsTheListRatherThanAskingForever() throws {
        let h = visibleStore()
        try h.client.answerPage(.success(Self.page(1...50, next: "c50")))
        h.hops.drain()
        h.store.loadMore()
        // the server repeats rows the list has, with a cursor
        try h.client.answerPage(.success(Self.page(41...50, next: "c50")))
        h.hops.drain()
        #expect(h.store.state.rows.count == 50)
        #expect(h.store.state.next == nil)
        h.store.loadMore()
        #expect(h.client.pageRequests.count == 2)
    }

    @Test func aFailedPageParksTheListUntilItsRetry() throws {
        let h = visibleStore()
        try h.client.answerPage(.success(Self.page(1...50, next: "c50")))
        h.hops.drain()
        h.store.loadMore()
        try h.client.answerPage(.failure(SnTopRequestFailed()))
        h.hops.drain()
        #expect(h.store.state.pageFailed)
        // the rows stay
        #expect(h.store.state.listContent == .list)
        #expect(h.store.state.rows.count == 50)

        // scrolling near the end does not ask again
        h.store.loadMore()
        #expect(h.client.pageRequests.count == 2)

        // the retry row asks for the same page
        h.store.retryList()
        #expect(h.client.pageRequests.count == 3)
        #expect(h.client.pageRequests.last == PageRequest(limit: 50, cursor: "c50", snapshot: ""))
        #expect(!h.store.state.pageFailed)
    }

    @Test func aPageFromAnotherSnapshotStartsTheListOver() throws {
        let h = visibleStore()
        try h.client.answerPage(.success(Self.page(1...50, next: "c50", snapshot: Self.snapshot("s1"))))
        h.hops.drain()
        h.store.loadMore()
        try h.client.answerPage(.success(Self.page(51...100, next: "c100", snapshot: Self.snapshot("s2", tempo: 101))))
        h.hops.drain()
        // the rows of two tempos never mix: the first page again
        #expect(h.client.pageRequests.last == PageRequest(limit: 50, cursor: "", snapshot: ""))
        #expect(h.store.state.rows.map(\.position) == Array(1...50))
    }

    // MARK: seeks

    @Test func aSeekToALoadedRowScrollsAtOnce() throws {
        let h = visibleStore()
        try h.client.answerPage(.success(Self.page(1...50, next: "c50")))
        h.hops.drain()

        h.store.seek(to: 30)
        #expect(h.store.state.scrollRequest?.target == .position(30))
        #expect(h.store.state.seekTarget == nil)
        #expect(h.client.pageRequests.count == 1)
    }

    @Test func aSeekPastTheLoadedRowsLoadsThroughThemAndThenScrolls() throws {
        let h = visibleStore()
        try h.client.answerPage(.success(Self.page(1...50, next: "c50")))
        h.hops.drain()

        h.store.seek(to: 300)
        #expect(h.store.state.seekTarget == 300)
        #expect(h.client.pageRequests.last == PageRequest(limit: 200, cursor: "c50", snapshot: ""))
        #expect(h.store.state.scrollRequest == nil)

        try h.client.answerPage(.success(Self.page(51...250, next: "c250")))
        h.hops.drain()
        // still short of 300: the next page, just far enough
        #expect(h.client.pageRequests.last == PageRequest(limit: 50, cursor: "c250", snapshot: ""))
        #expect(h.store.state.scrollRequest == nil)

        try h.client.answerPage(.success(Self.page(251...300, next: "c300")))
        h.hops.drain()
        #expect(h.store.state.seekTarget == nil)
        #expect(h.store.state.scrollRequest?.target == .position(300))
    }

    @Test func aSeekPastTheEndOfTheBoardLandsOnItsLastRow() throws {
        let h = visibleStore()
        // a board of 120 ranked networks
        try h.client.answerPage(.success(Self.page(1...50, next: "c50", snapshot: Self.snapshot(total: 120))))
        h.hops.drain()
        #expect(h.store.state.trackTotal == 120)

        h.store.seek(to: 400)
        // the indicator spans 120 positions: the seek is clamped to them
        #expect(h.store.state.seekTarget == 120)
        try h.client.answerPage(.success(Self.page(51...118, next: nil, snapshot: Self.snapshot(total: 120))))
        h.hops.drain()
        #expect(h.store.state.seekTarget == nil)
        #expect(h.store.state.scrollRequest?.target == .position(118))
    }

    @Test func aFailedSeekStopsAndLeavesTheRetryRow() throws {
        let h = visibleStore()
        try h.client.answerPage(.success(Self.page(1...50, next: "c50")))
        h.hops.drain()
        h.store.seek(to: 300)
        try h.client.answerPage(.failure(SnTopRequestFailed()))
        h.hops.drain()
        #expect(h.store.state.seekTarget == nil)
        #expect(h.store.state.pageFailed)
        #expect(h.store.state.scrollRequest == nil)
    }

    @Test func theTabResetScrollsToTheTopAndStopsASeek() throws {
        let h = visibleStore()
        try h.client.answerPage(.success(Self.page(1...50, next: "c50")))
        h.hops.drain()
        h.store.seek(to: 300)
        #expect(h.store.state.seekTarget == 300)

        h.store.tabTapped()
        #expect(h.store.state.seekTarget == nil)
        #expect(h.store.state.scrollRequest?.target == .top)

        // the page in flight lands, and nothing scrolls away from the top
        try h.client.answerPage(.success(Self.page(51...250, next: "c250")))
        h.hops.drain()
        #expect(h.store.state.scrollRequest?.target == .top)
        // each tap is its own request, the selected tab's included
        let serial = h.store.state.scrollRequest?.serial
        h.store.tabTapped()
        #expect(h.store.state.scrollRequest?.serial != serial)
    }

    // MARK: the card

    @Test func theCardLandsAndAFailedRefreshKeepsIt() throws {
        let h = visibleStore()
        try h.client.answerMe(.success(Self.meResult()))
        h.hops.drain()
        guard case .loaded(let me) = h.store.state.cardContent else {
            Issue.record("the card should be loaded")
            return
        }
        #expect(me.rankedRow?.position == 173)
        #expect(h.store.state.ownRow?.position == 173)

        h.store.refresh()
        try h.client.answerMe(.failure(SnTopRequestFailed()))
        h.hops.drain()
        #expect(h.store.state.meFailed)
        #expect(h.store.state.cardContent == .loaded(me))
    }

    @Test func aCardThatNeverLoadedShowsTheRetryRow() throws {
        let h = visibleStore()
        try h.client.answerMe(.failure(SnTopRequestFailed()))
        h.hops.drain()
        #expect(h.store.state.cardContent == .failed)
        h.store.retryMe()
        #expect(h.client.meAnswers.count == 2)
        #expect(h.store.state.cardContent == .loading)
    }

    @Test func signedOutShowsThePublicListAndNoCard() throws {
        let h = visibleStore(signedIn: false)
        #expect(h.store.state.cardContent == .signedOut)
        // the public list loads; the caller's detail is never asked for
        #expect(h.client.pageRequests.count == 1)
        #expect(h.client.meAnswers.isEmpty)
        try h.client.answerPage(.success(Self.page(1...50, next: "c50", me: Self.myRow)))
        h.hops.drain()
        #expect(h.store.state.meRow == nil)
        #expect(h.store.state.ownRow == nil)
    }

    @Test func signingOutDropsTheCardAndALateAnswerDoesNotBringItBack() throws {
        let h = visibleStore()
        h.store.setSignedIn(false)
        try h.client.answerMe(.success(Self.meResult()))
        h.hops.drain()
        #expect(h.store.state.cardContent == .signedOut)
        #expect(h.store.state.me == nil)
    }

    // MARK: refresh

    @Test func aFailedRefreshKeepsTheRowsWithANotice() throws {
        let h = visibleStore()
        try h.client.answerPage(.success(Self.page(1...50, next: "c50")))
        h.hops.drain()

        h.store.refresh()
        #expect(h.client.pageRequests.last == PageRequest(limit: 50, cursor: "", snapshot: ""))
        // the rows stay on screen while the refresh is in flight
        #expect(h.store.state.rows.count == 50)
        try h.client.answerPage(.failure(SnTopRequestFailed()))
        h.hops.drain()
        #expect(h.store.state.listContent == .list)
        #expect(h.store.state.refreshFailed)
        #expect(h.store.state.rows.count == 50)
    }

    @Test func onlyTheNewestLoadLands() throws {
        let h = visibleStore()
        h.store.refresh()
        // the refresh's answer comes first, then the replaced load's
        h.client.answerPage(at: 1, .success(Self.page(1...50, next: "new", snapshot: Self.snapshot("s2", tempo: 101))))
        h.client.answerPage(at: 0, .success(Self.page(1...50, next: "old", snapshot: Self.snapshot("s1"))))
        h.hops.drain()
        #expect(h.store.state.snapshot?.id == "s2")
        #expect(h.store.state.next == "new")
    }

    @Test func aPageInFlightDoesNotLandOnTheListARefreshReplaced() throws {
        let h = visibleStore()
        try h.client.answerPage(.success(Self.page(1...50, next: "c50")))
        h.hops.drain()
        h.store.loadMore()
        h.store.refresh()
        // the old list's next page answers after the refresh started
        h.client.answerPage(at: 1, .success(Self.page(51...100, next: "c100")))
        h.hops.drain()
        #expect(h.store.state.rows.count == 50)
        #expect(h.store.state.listLoading)
    }

    @Test func aPullWaitsForTheListAndTheCard() async throws {
        let h = visibleStore()
        try h.client.answerPage(.success(Self.page(1...50, next: "c50")))
        try h.client.answerMe(.success(Self.meResult()))
        h.hops.drain()

        let pull = Task { @MainActor in
            await h.store.refreshAndWait()
            return true
        }
        // the pull's requests are out; answer them and let them land
        while h.client.pageRequests.count < 2 || h.client.meAnswers.count < 2 {
            await Task.yield()
        }
        try h.client.answerPage(.success(Self.page(1...50, next: "c50")))
        try h.client.answerMe(.success(Self.meResult()))
        h.hops.drain()
        #expect(await pull.value)
    }

    @Test func visibleAgainReloadsOnlyAfterFiveMinutes() throws {
        let h = visibleStore()
        try h.client.answerPage(.success(Self.page(1...50, next: "c50")))
        try h.client.answerMe(.success(Self.meResult()))
        h.hops.drain()

        h.store.setOnScreen(false)
        h.clock.now = h.clock.now.addingTimeInterval(4 * 60)
        h.store.setOnScreen(true)
        #expect(h.client.pageRequests.count == 1)
        #expect(h.client.meAnswers.count == 1)

        h.store.setOnScreen(false)
        h.clock.now = h.clock.now.addingTimeInterval(60)
        h.store.setOnScreen(true)
        #expect(h.client.pageRequests.count == 2)
        #expect(h.client.meAnswers.count == 2)
    }

    // MARK: sessions

    @Test func theSameSessionKeepsItsBoardThroughANewApiWrapper() throws {
        let h = visibleStore()
        try h.client.answerPage(.success(Self.page(1...50, next: "c50")))
        h.hops.drain()
        // the session's api hands out a new wrapper on every read
        h.store.setClient(FakeClient(), session: h.session)
        #expect(h.store.state.rows.count == 50)
    }

    @Test func anotherSessionStartsOverAndTheOldAnswersDoNotLand() throws {
        let h = visibleStore()
        let other = FakeClient()
        let otherSession = Session()
        h.store.setClient(other, session: otherSession)
        #expect(h.store.state.listContent == .loading)
        #expect(other.pageRequests.count == 1)

        // the old session's first page answers late
        try h.client.answerPage(.success(Self.page(1...50, next: "c50")))
        h.hops.drain()
        #expect(h.store.state.listContent == .loading)
        #expect(h.store.state.rows.isEmpty)
    }
}
