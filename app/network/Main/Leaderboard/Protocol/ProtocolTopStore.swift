//
//  ProtocolTopStore.swift
//  URnetwork
//
//  The Protocol leaderboard (owner decision 2026-10-29, LEADERTOP): the top
//  400 of GET /sn/top, paged 50 at a time over the server's cursor, and the
//  caller's own status from GET /sn/top/me. There is no sdk view controller
//  for the board, so this store owns the pages and their loads; the client
//  only runs the requests. The server ranks: nothing here sorts or ranks,
//  rows are only kept in the server's position order.
//
//  Everything runs on the main actor. The client answers on an sdk thread
//  and each answer hops to the main queue before it touches the store. Loads
//  are numbered: an answer to a load that a newer one replaced, or to a
//  client the store no longer uses, changes nothing.
//

import Foundation

/// What the list area shows.
enum ProtocolListContent: Equatable {
    /// the first page has not landed: placeholder rows
    case loading
    /// the first page failed: the standard retry row
    case failed
    /// the snapshot ranks nobody yet
    case empty
    case list
}

/// What the own-status card shows.
enum ProtocolCardContent: Equatable {
    /// no session to ask for the caller's status: no card
    case signedOut
    /// a placeholder card the size of the real one
    case loading
    /// the standard retry row in the card's place
    case failed
    case loaded(SnTopMeInfo)
}

/// A scroll the list makes, numbered so the same target twice is two scrolls.
struct ProtocolScrollRequest: Equatable {

    enum Target: Equatable {
        /// the top of the tab: the tab reset
        case top
        /// a ranked row, by its position
        case position(Int)
    }

    let target: Target
    let serial: Int
}

/// One read of the board and the caller's status.
struct ProtocolTopState: Equatable {

    /// the board lists the top 400 (Q5)
    static let maxPosition = 400

    /// the list's snapshot: its pages are pinned to it
    var snapshot: SnTopSnapshotInfo? = nil
    /// by position, 1 up, without gaps
    var rows: [SnTopRowInfo] = []
    /// the caller's row from GET /sn/top, wherever it ranks
    var meRow: SnTopRowInfo? = nil
    /// the next page's cursor; nil at the end of the board
    var next: String? = nil
    /// a first page has landed
    var listLoaded = false
    /// a first page is in flight: the first load or a refresh
    var listLoading = false
    /// the last first page failed, and none is in flight
    var listFailed = false
    /// the next page is in flight
    var pageLoading = false
    /// the last next page failed; only the retry row asks again
    var pageFailed = false

    /// there is a session to ask GET /sn/top/me for
    var signedIn = true
    var me: SnTopMeInfo? = nil
    var meSnapshot: SnTopSnapshotInfo? = nil
    var meLoaded = false
    var meLoading = false
    var meFailed = false

    /// the position a seek is loading pages down to
    var seekTarget: Int? = nil
    /// the latest scroll the list should make
    var scrollRequest: ProtocolScrollRequest? = nil

    var lastPosition: Int {
        rows.last?.position ?? 0
    }

    /// pages remain below the loaded rows
    var hasMore: Bool {
        listLoaded && next != nil && lastPosition < Self.maxPosition
    }

    var listContent: ProtocolListContent {
        if !listLoaded {
            return listFailed ? .failed : .loading
        }
        return rows.isEmpty ? .empty : .list
    }

    /// A refresh after the rows were shown failed: the rows stay, with a notice.
    var refreshFailed: Bool {
        listLoaded && listFailed
    }

    var cardContent: ProtocolCardContent {
        if !signedIn {
            return .signedOut
        }
        if let me {
            // a failed refresh keeps the card it had
            return .loaded(me)
        }
        return meFailed ? .failed : .loading
    }

    /// The newer of the list's snapshot and the card's: the banner's.
    var currentSnapshot: SnTopSnapshotInfo? {
        switch (snapshot, meSnapshot) {
        case let (list?, card?):
            return card.tempoIndex > list.tempoIndex ? card : list
        case let (list?, nil):
            return list
        case let (nil, card?):
            return card
        case (nil, nil):
            return nil
        }
    }

    /// The positions the indicator spans: 1 to the end of the board.
    var trackTotal: Int {
        min(Self.maxPosition, max(lastPosition, snapshot?.totalRanked ?? 0))
    }

    /// The caller's row: the card's, else the list's; nil when unranked.
    var ownRow: SnTopRowInfo? {
        if let row = me?.rankedRow {
            return row
        }
        if let row = meRow, row.position > 0 {
            return row
        }
        return nil
    }
}

/// The paging rules, pure so they are tested without a store.
enum ProtocolTopRows {

    /// A first page as the list keeps it: positions 1 to 400, in order, once each.
    static func firstPage(_ rows: [SnTopRowInfo]) -> [SnTopRowInfo] {
        appending(rows, to: [])
    }

    /// A next page after `existing`: only positions below the last one kept
    /// and within the board, in order, once each.
    static func appending(_ page: [SnTopRowInfo], to existing: [SnTopRowInfo]) -> [SnTopRowInfo] {
        var last = existing.last?.position ?? 0
        var rows = existing
        for row in page.sorted(by: { $0.position < $1.position }) {
            if row.position > last && row.position <= ProtocolTopState.maxPosition {
                rows.append(row)
                last = row.position
            }
        }
        return rows
    }

    /// The cursor to follow: none when the server sent none, or once the
    /// board's last position is loaded.
    static func nextCursor(_ next: String?, lastPosition: Int) -> String? {
        guard let next, !next.isEmpty, lastPosition < ProtocolTopState.maxPosition else {
            return nil
        }
        return next
    }

    /// The next page's size: a page, or enough to reach a seek's target in
    /// one request (at most the api's 200), and never past the board's end.
    static func limit(lastPosition: Int, target: Int?, pageSize: Int, maxLimit: Int) -> Int {
        let remaining = ProtocolTopState.maxPosition - lastPosition
        if remaining <= 0 {
            return 0
        }
        var wanted = pageSize
        if let target, target > lastPosition {
            wanted = max(pageSize, target - lastPosition)
        }
        return min(wanted, maxLimit, remaining)
    }
}

/**
 * Publishes the Protocol leaderboard for its tab and for the second pane.
 *
 * Loads: the first page and the caller's status load the first time the tab
 * is visible (on screen and the app presenting), again when it becomes
 * visible after five minutes, and on refresh. A refresh restarts the list at
 * the first page; the rows on screen stay until the new page lands.
 *
 * Pages: the list asks for the next page near its end. A failed page parks
 * the list until its retry row asks again. A seek (the position indicator's
 * release) scrolls to a loaded row at once, or loads the pages down to it,
 * up to 200 rows a request, and then scrolls.
 */
@MainActor
final class ProtocolTopStore: ObservableObject {

    static let pageSize = 50
    /// the api's largest page
    static let maxLimit = 200
    /// a tab visible again reloads when its data is older than this
    static let refreshAfter: TimeInterval = 5 * 60

    @Published private(set) var state = ProtocolTopState()

    /// Runs `work` on the main actor later. Tests pass a queue they drain.
    typealias Dispatch = (@escaping @MainActor () -> Void) -> Void

    nonisolated static func dispatchOnMainQueue(_ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                work()
            }
        }
    }

    private var client: SnTopClient?
    private weak var session: AnyObject?
    private let dispatch: Dispatch
    private let now: () -> Date

    private var onScreen = false
    private var presentationActive = false
    private var visible = false

    // the newest load of each kind; an answer to any other changes nothing
    private var listGeneration: UInt64 = 0
    private var meGeneration: UInt64 = 0
    private var listLoadedAt: Date? = nil
    private var meLoadedAt: Date? = nil
    private var scrollSerial = 0
    // pulls to refresh, waiting for the list and the card to settle
    private var refreshWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        client: SnTopClient? = nil,
        dispatch: @escaping Dispatch = ProtocolTopStore.dispatchOnMainQueue,
        now: @escaping () -> Date = Date.init
    ) {
        self.client = client
        self.dispatch = dispatch
        self.now = now
    }

    // MARK: Lifecycle

    /// The tab appeared or disappeared.
    func setOnScreen(_ onScreen: Bool) {
        self.onScreen = onScreen
        updateVisible()
    }

    /// The app started or stopped presenting (scene active, window visible).
    func setPresentationActive(_ active: Bool) {
        guard presentationActive != active else {
            return
        }
        presentationActive = active
        updateVisible()
    }

    /**
     * The api the board loads through, nil without one, and the session it
     * belongs to (the sdk device). The same session keeps its board: the
     * session's api hands out a new wrapper on every read, so only another
     * session, or a client where there was none, starts over, and nothing
     * the old one answers lands.
     */
    func setClient(_ client: SnTopClient?, session: AnyObject?) {
        let sameSession = session != nil && session === self.session && (client == nil) == (self.client == nil)
        self.client = client
        if sameSession {
            return
        }
        self.session = session
        listGeneration += 1
        meGeneration += 1
        let signedIn = state.signedIn
        state = ProtocolTopState()
        state.signedIn = signedIn
        listLoadedAt = nil
        meLoadedAt = nil
        resumeRefreshWaiters()
        if visible && client != nil {
            loadFirstPage()
            loadMe()
        }
        updateVisible()
    }

    /// Whether there is a session to ask for the caller's status. Signed
    /// out, the card goes and only the public list shows.
    func setSignedIn(_ signedIn: Bool) {
        guard signedIn != state.signedIn else {
            return
        }
        state.signedIn = signedIn
        meGeneration += 1
        state.me = nil
        state.meSnapshot = nil
        state.meLoaded = false
        state.meLoading = false
        state.meFailed = false
        state.meRow = nil
        meLoadedAt = nil
        if visible {
            // the list's own row follows the session too
            loadFirstPage()
            loadMe()
        }
        resumeRefreshWaitersIfSettled()
    }

    private func updateVisible() {
        let nextVisible = onScreen && presentationActive && client != nil
        guard nextVisible != visible else {
            return
        }
        visible = nextVisible
        if nextVisible {
            let time = now()
            if !state.listLoading && (!state.listLoaded || isOld(listLoadedAt, at: time)) {
                loadFirstPage()
            }
            if !state.meLoading && (!state.meLoaded || isOld(meLoadedAt, at: time)) {
                loadMe()
            }
        }
    }

    private func isOld(_ loadedAt: Date?, at time: Date) -> Bool {
        guard let loadedAt else {
            return true
        }
        return time.timeIntervalSince(loadedAt) >= Self.refreshAfter
    }

    // MARK: Intents

    /// The toolbar's refresh, or the name switch changed: the list from its
    /// first page, and the card.
    func refresh() {
        loadFirstPage()
        loadMe()
    }

    /**
     * A pull: refreshes, then returns once the list and the card have
     * settled, so the pull indicator stays until they land. Returns at once
     * without a client.
     */
    func refreshAndWait() async {
        guard client != nil else {
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // waiting before the loads start, so no answer can come first
            refreshWaiters.append(continuation)
            refresh()
        }
    }

    /// The list's retry row: the first page again, or the page that failed.
    func retryList() {
        if state.listLoaded && state.pageFailed && !state.listFailed {
            state.pageFailed = false
            loadNextPage()
        } else {
            loadFirstPage()
        }
    }

    /// The card's retry row.
    func retryMe() {
        if !state.meLoading {
            loadMe()
        }
    }

    /// The list scrolled near its end (PointsLeaderboardPaging decides when).
    func loadMore() {
        loadNextPage()
    }

    /**
     * The position indicator was released on `position`: the list scrolls to
     * that row, at once when it is loaded, else once the pages down to it
     * have landed. A position past the board's end scrolls to its last row.
     */
    func seek(to position: Int) {
        guard state.listLoaded, !state.rows.isEmpty else {
            return
        }
        let target = min(max(position, 1), max(state.trackTotal, 1))
        if target <= state.lastPosition {
            state.seekTarget = nil
            requestScroll(.position(target))
            return
        }
        guard state.hasMore else {
            state.seekTarget = nil
            requestScroll(.position(state.lastPosition))
            return
        }
        state.seekTarget = target
        // a seek is a deliberate ask: it retries a page that failed
        state.pageFailed = false
        if !state.pageLoading {
            loadNextPage()
        }
    }

    /// The tab was tapped, the selected one included: back to the top. A
    /// seek in flight stops there.
    func tabTapped() {
        state.seekTarget = nil
        requestScroll(.top)
    }

    private func requestScroll(_ target: ProtocolScrollRequest.Target) {
        scrollSerial += 1
        state.scrollRequest = ProtocolScrollRequest(target: target, serial: scrollSerial)
    }

    // MARK: Loads

    /// Starts a first page that replaces the list's loads in flight.
    private func loadFirstPage() {
        guard let client else {
            return
        }
        listGeneration += 1
        let generation = listGeneration
        state.listLoading = true
        state.listFailed = false
        // a next page or a seek in flight belongs to the list this replaces
        state.pageLoading = false
        state.pageFailed = false
        state.seekTarget = nil
        let dispatch = self.dispatch
        client.fetchTop(limit: Self.pageSize, cursor: "", snapshot: "") { [weak self] result in
            dispatch {
                self?.firstPageLanded(result, generation: generation)
            }
        }
    }

    private func firstPageLanded(_ result: Result<SnTopPageInfo, SnTopRequestFailed>, generation: UInt64) {
        guard generation == listGeneration else {
            return
        }
        state.listLoading = false
        switch result {
        case .success(let page):
            state.snapshot = page.snapshot
            state.rows = ProtocolTopRows.firstPage(page.rows)
            state.next = ProtocolTopRows.nextCursor(page.next, lastPosition: state.lastPosition)
            state.meRow = state.signedIn ? page.me : nil
            state.listLoaded = true
            listLoadedAt = now()
        case .failure:
            state.listFailed = true
        }
        resumeRefreshWaitersIfSettled()
    }

    private func loadNextPage() {
        guard let client,
              state.listLoaded,
              !state.listLoading,
              !state.pageLoading,
              !state.pageFailed,
              let cursor = state.next,
              state.snapshot != nil else {
            return
        }
        let limit = ProtocolTopRows.limit(
            lastPosition: state.lastPosition,
            target: state.seekTarget,
            pageSize: Self.pageSize,
            maxLimit: Self.maxLimit
        )
        guard limit > 0 else {
            return
        }
        let generation = listGeneration
        state.pageLoading = true
        let dispatch = self.dispatch
        // the cursor pins the page to the list's snapshot
        client.fetchTop(limit: limit, cursor: cursor, snapshot: "") { [weak self] result in
            dispatch {
                self?.pageLanded(result, generation: generation)
            }
        }
    }

    private func pageLanded(_ result: Result<SnTopPageInfo, SnTopRequestFailed>, generation: UInt64) {
        guard generation == listGeneration else {
            return
        }
        state.pageLoading = false
        switch result {
        case .success(let page):
            if let current = state.snapshot, page.snapshot.id != current.id {
                // the pinned snapshot is gone: the rows so far rank another
                // tempo, so the list starts over on the new one
                loadFirstPage()
                return
            }
            let before = state.lastPosition
            state.rows = ProtocolTopRows.appending(page.rows, to: state.rows)
            // a page that adds nothing ends the list, so a cursor that never
            // advances is not followed again and again
            state.next = state.lastPosition > before
                ? ProtocolTopRows.nextCursor(page.next, lastPosition: state.lastPosition)
                : nil
            if state.signedIn, let me = page.me {
                state.meRow = me
            }
            continueSeek()
        case .failure:
            state.pageFailed = true
            state.seekTarget = nil
        }
    }

    private func continueSeek() {
        guard let target = state.seekTarget else {
            return
        }
        if state.lastPosition >= target {
            state.seekTarget = nil
            requestScroll(.position(target))
        } else if state.hasMore {
            loadNextPage()
        } else {
            // the board ends above the target: its last row
            state.seekTarget = nil
            if state.lastPosition > 0 {
                requestScroll(.position(state.lastPosition))
            }
        }
    }

    private func loadMe() {
        guard let client, state.signedIn else {
            return
        }
        meGeneration += 1
        let generation = meGeneration
        state.meLoading = true
        state.meFailed = false
        let dispatch = self.dispatch
        client.fetchTopMe { [weak self] result in
            dispatch {
                self?.meLanded(result, generation: generation)
            }
        }
    }

    private func meLanded(_ result: Result<SnTopMeResultInfo, SnTopRequestFailed>, generation: UInt64) {
        guard generation == meGeneration, state.signedIn else {
            return
        }
        state.meLoading = false
        switch result {
        case .success(let answer):
            state.me = answer.me
            state.meSnapshot = answer.snapshot
            state.meLoaded = true
            meLoadedAt = now()
        case .failure:
            // a card already shown stays
            state.meFailed = true
        }
        resumeRefreshWaitersIfSettled()
    }

    private func resumeRefreshWaitersIfSettled() {
        guard !state.listLoading && !state.meLoading else {
            return
        }
        resumeRefreshWaiters()
    }

    private func resumeRefreshWaiters() {
        let waiters = refreshWaiters
        refreshWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }
}
