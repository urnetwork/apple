//
//  ApiKeysStoreTests.swift
//  networkTests
//

import Foundation
import Testing
import URnetworkSdk
@testable import URnetwork

/**
 * Account > API keys' store over a fake client: the loads its lifecycle and
 * intents start, that only the newest load lands, the create sheet's steps
 * and the key it drops once the sheet has closed, the confirmation every
 * delete waits for, and that nothing lands after the screen is gone. The
 * client answers when a test says, and the answers' hops to the main queue
 * go to a queue each test drains itself, so nothing waits, polls or reads a
 * clock.
 */
@MainActor
struct ApiKeysStoreTests {

    // test-only key ids, in creation order
    private static let olderKey = "0193b1e6-0000-4000-8000-00000000000a"
    private static let newerKey = "0193b1e7-0000-4000-8000-00000000000b"
    private static let newestKey = "0193b1e8-0000-4000-8000-00000000000c"
    // a test-only key in the server's form, never a real one
    private static let secret = "urn_TESTONLY00000000000000000000000000000000000000000000"

    private static let older = ApiKeyItem(id: olderKey, name: "home server", createTimeMillis: 1_790_000_000_000)
    private static let newer = ApiKeyItem(id: newerKey, name: "", createTimeMillis: 1_790_500_000_000)
    private static let newest = ApiKeyItem(id: newestKey, name: "build bot", createTimeMillis: 1_791_000_000_000)

    private typealias ListDone = @Sendable (Result<[ApiKeyItem], ApiKeysRequestFailed>) -> Void
    private typealias CreateDone = @Sendable (Result<ApiKeyCreatedItem, ApiKeysRequestFailed>) -> Void
    private typealias RemoveDone = @Sendable (Result<Void, ApiKeysRequestFailed>) -> Void

    /// Records each request and answers it when the test says.
    private final class FakeClient: ApiKeysClient {
        var log: [String] = []
        var fetches: [ListDone] = []
        var creates: [CreateDone] = []
        var removes: [RemoveDone] = []

        func fetchApiKeys(_ done: @escaping ListDone) {
            log.append("fetch")
            fetches.append(done)
        }

        func createApiKey(named name: String, _ done: @escaping CreateDone) {
            log.append("create \(name)")
            creates.append(done)
        }

        func removeApiKey(id: String, _ done: @escaping RemoveDone) {
            log.append("remove \(id)")
            removes.append(done)
        }

        /// Answers the newest fetch, as the SDK would from its own thread.
        func answerFetch(_ result: Result<[ApiKeyItem], ApiKeysRequestFailed>) throws {
            let done = try #require(fetches.last)
            done(result)
        }

        func answerCreate(_ result: Result<ApiKeyCreatedItem, ApiKeysRequestFailed>) throws {
            let done = try #require(creates.last)
            done(result)
        }

        func answerRemove(_ result: Result<Void, ApiKeysRequestFailed>) throws {
            let done = try #require(removes.last)
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
        func run() {
            let work = pending
            pending = []
            for hop in work {
                hop()
            }
        }
    }

    /// Set when a pull's refresh returns.
    private final class Flag {
        var value = false
    }

    private func makeStore() -> (ApiKeysStore, FakeClient, Hops) {
        let client = FakeClient()
        let hops = Hops()
        let store = ApiKeysStore(client: client, dispatch: hops.dispatch)
        return (store, client, hops)
    }

    /// On screen with the app presenting, the first load answered with
    /// `keys` (the older and the newer key when nil).
    private func showing(_ keys: [ApiKeyItem]? = nil) throws -> (ApiKeysStore, FakeClient, Hops) {
        let (store, client, hops) = makeStore()
        store.setPresentationActive(true)
        store.setOnScreen(true)
        let load = try #require(client.fetches.last)
        load(.success(keys ?? [Self.older, Self.newer]))
        hops.run()
        client.log = []
        return (store, client, hops)
    }

    /// Runs what is queued on the main queue so far: a task's next step.
    private func drainMainQueue() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }

    // MARK: Lifecycle

    // on screen while the app is in the background, or the app presenting
    // with the screen not shown: nothing loads
    @Test func nothingLoadsUntilTheScreenShowsWhileTheAppPresents() {
        let (store, client, _) = makeStore()
        store.setOnScreen(true)
        store.setOnScreen(false)
        store.setPresentationActive(true)
        #expect(client.log.isEmpty)
        #expect(store.snapshot.content == .loading)
    }

    @Test func appearingLoadsTheList() throws {
        let (store, client, hops) = makeStore()
        store.setPresentationActive(true)
        store.setOnScreen(true)
        #expect(client.log == ["fetch"])
        #expect(store.snapshot.loading)
        #expect(store.snapshot.content == .loading)

        let load = try #require(client.fetches.first)
        load(.success([Self.older, Self.newer]))
        // nothing lands until the hop to the main queue runs
        #expect(store.snapshot.loading)
        hops.run()
        #expect(store.snapshot.content == .list)
        #expect(!store.snapshot.loading)
        #expect(!store.snapshot.refreshing)
    }

    // the list may have changed elsewhere (ur.io, the API) while the screen
    // or the app was away
    @Test func showingAgainLoadsAgain() throws {
        let (store, client, _) = try showing()
        store.setOnScreen(false)
        store.setOnScreen(true)
        store.setPresentationActive(false)
        store.setPresentationActive(true)
        #expect(client.log == ["fetch", "fetch"])
    }

    @Test func repeatedLifecycleCallsAreIgnored() throws {
        let (store, client, _) = try showing()
        store.setPresentationActive(true)
        store.setOnScreen(true)
        #expect(client.log.isEmpty)
    }

    @Test func theListIsNewestFirst() throws {
        let (store, _, _) = try showing([Self.older, Self.newest, Self.newer])
        #expect(store.snapshot.keys == [Self.newest, Self.newer, Self.older])
    }

    @Test func noKeysIsEmpty() throws {
        let (store, _, _) = try showing([])
        #expect(store.snapshot.content == .empty)
    }

    // MARK: Loads

    @Test func aFailedFirstLoadOffersRetryAndARetryShowsProgress() throws {
        let (store, client, hops) = makeStore()
        store.setPresentationActive(true)
        store.setOnScreen(true)
        try client.answerFetch(.failure(ApiKeysRequestFailed()))
        hops.run()
        #expect(store.snapshot.content == .loadFailed)

        store.refresh()
        #expect(store.snapshot.content == .loading)
        try client.answerFetch(.success([Self.older]))
        hops.run()
        #expect(store.snapshot.content == .list)
        #expect(store.snapshot.keys == [Self.older])
    }

    @Test func aFailedRefreshKeepsTheListWithANotice() throws {
        let (store, client, hops) = try showing()
        store.refresh()
        #expect(store.snapshot.refreshing)
        #expect(store.snapshot.keys == [Self.newer, Self.older])

        try client.answerFetch(.failure(ApiKeysRequestFailed()))
        hops.run()
        #expect(store.snapshot.content == .list)
        #expect(store.snapshot.refreshFailed)
        #expect(store.snapshot.keys == [Self.newer, Self.older])

        // Retry hides the notice while it loads
        store.refresh()
        #expect(!store.snapshot.refreshFailed)
    }

    // two loads in flight answer in the other order: the older one's list,
    // read before the newer one's, never replaces it
    @Test func aLateAnswerNeverReplacesANewerList() throws {
        let (store, client, hops) = try showing([Self.older])
        store.refresh()
        let first = try #require(client.fetches.last)
        store.refresh()
        let second = try #require(client.fetches.last)

        second(.success([Self.older, Self.newest]))
        hops.run()
        #expect(store.snapshot.keys == [Self.newest, Self.older])
        #expect(!store.snapshot.loading)

        first(.success([Self.older]))
        hops.run()
        #expect(store.snapshot.keys == [Self.newest, Self.older])
        #expect(!store.snapshot.loading)
    }

    // the older load answering first still leaves the newer one in flight
    @Test func anEarlierLoadAnsweringFirstChangesNothing() throws {
        let (store, client, hops) = try showing([Self.older])
        store.refresh()
        let first = try #require(client.fetches.last)
        store.refresh()

        first(.failure(ApiKeysRequestFailed()))
        hops.run()
        #expect(store.snapshot.loading)
        #expect(!store.snapshot.refreshFailed)
        #expect(store.snapshot.keys == [Self.older])
    }

    // the pull indicator stays until the list it asked for has landed
    @Test func pullToRefreshWaitsForTheLoadItStarted() async throws {
        let (store, client, hops) = try showing()
        let finished = Flag()
        let pull = Task {
            await store.refreshAndWait()
            finished.value = true
        }
        await drainMainQueue()
        #expect(client.log == ["fetch"])
        #expect(!finished.value)

        try client.answerFetch(.success([Self.newest]))
        await drainMainQueue()
        #expect(!finished.value)

        hops.run()
        await pull.value
        #expect(finished.value)
        #expect(store.snapshot.keys == [Self.newest])
    }

    // a second pull replaces the first one's load: both end with the newer
    @Test func pullsEndWithTheNewestLoad() async throws {
        let (store, client, hops) = try showing()
        let firstPull = Task {
            await store.refreshAndWait()
        }
        await drainMainQueue()
        let firstLoad = try #require(client.fetches.last)
        let secondPull = Task {
            await store.refreshAndWait()
        }
        await drainMainQueue()
        #expect(client.log == ["fetch", "fetch"])

        firstLoad(.success([Self.older]))
        hops.run()
        try client.answerFetch(.success([Self.newest]))
        hops.run()
        await firstPull.value
        await secondPull.value
        #expect(store.snapshot.keys == [Self.newest])
    }

    @Test func pullToRefreshEndsWhenTheScreenIsDisposed() async throws {
        let (store, _, _) = try showing()
        let pull = Task {
            await store.refreshAndWait()
        }
        await drainMainQueue()
        store.close()
        await pull.value
    }

    // MARK: Close

    // no answer lands after the screen is gone, including a hop already
    // queued
    @Test func nothingLandsAfterClose() throws {
        let (store, client, hops) = try showing()
        let before = store.snapshot
        store.refresh()
        let load = try #require(client.fetches.last)
        store.startCreate()
        store.create(name: "home server")
        let create = try #require(client.creates.last)
        store.requestDelete(keyId: Self.olderKey)
        let confirmation = try #require(store.confirmation)
        store.confirm(confirmation)
        let remove = try #require(client.removes.last)
        load(.success([Self.newest]))

        store.close()
        hops.run()
        create(.success(ApiKeyCreatedItem(id: Self.newestKey, name: "home server", apiKey: Self.secret)))
        remove(.success(()))
        hops.run()

        #expect(store.createStep == nil)
        #expect(!store.createSheetPresented)
        #expect(store.confirmation == nil)
        #expect(store.snapshot.keys == before.keys)
        // and nothing more is asked of the client
        client.log = []
        store.refresh()
        store.setOnScreen(false)
        store.setOnScreen(true)
        store.startCreate()
        #expect(client.log.isEmpty)
        #expect(store.createStep == nil)
    }

    // MARK: Create

    @Test func createOpensTheSheetOnItsNameForm() throws {
        let (store, client, _) = try showing()
        store.startCreate()
        #expect(store.createSheetPresented)
        #expect(store.createStep == .naming(failed: false))
        #expect(client.log.isEmpty)
    }

    @Test func createSendsTheTrimmedNameOnce() throws {
        let (store, client, _) = try showing()
        store.startCreate()
        store.create(name: "  home server \n")
        #expect(client.log == ["create home server"])
        #expect(store.createStep == .creating)

        // a repeated activation while it is in flight
        store.create(name: "home server")
        #expect(client.log == ["create home server"])
    }

    // the app always names a key
    @Test func aBlankNameSendsNothing() throws {
        let (store, client, _) = try showing()
        store.startCreate()
        store.create(name: "")
        store.create(name: " \t\n ")
        #expect(client.log.isEmpty)
        #expect(store.createStep == .naming(failed: false))
    }

    @Test func nothingIsCreatedWithoutTheSheet() throws {
        let (store, client, _) = try showing()
        store.create(name: "home server")
        #expect(client.log.isEmpty)
        #expect(store.createStep == nil)
    }

    @Test func aCreatedKeyIsShownAndTheListLoads() throws {
        let (store, client, hops) = try showing()
        store.startCreate()
        store.create(name: "build bot")
        let created = ApiKeyCreatedItem(id: Self.newestKey, name: "build bot", apiKey: Self.secret)
        try client.answerCreate(.success(created))
        #expect(store.createStep == .creating)
        hops.run()
        #expect(store.createStep == .created(created))
        #expect(client.log == ["create build bot", "fetch"])

        try client.answerFetch(.success([Self.older, Self.newer, Self.newest]))
        hops.run()
        #expect(store.snapshot.keys.first == Self.newest)
        // the list never has the key itself
        #expect(!String(describing: store.snapshot).contains(Self.secret))
    }

    // the name stays for another try; a failure may still have created a
    // key, so the list loads
    @Test func aFailedCreateSaysSoOnTheNameForm() throws {
        let (store, client, hops) = try showing()
        store.startCreate()
        store.create(name: "build bot")
        try client.answerCreate(.failure(ApiKeysRequestFailed()))
        hops.run()
        #expect(store.createStep == .naming(failed: true))
        #expect(store.createSheetPresented)
        #expect(client.log == ["create build bot", "fetch"])

        store.create(name: "build bot")
        #expect(store.createStep == .creating)
        #expect(client.log == ["create build bot", "fetch", "create build bot"])
    }

    // nothing closes the sheet while the server may be creating the key
    @Test func theSheetStaysWhileACreateIsInFlight() throws {
        let (store, _, _) = try showing()
        store.startCreate()
        store.create(name: "build bot")
        store.dismissCreate()
        #expect(store.createSheetPresented)
        #expect(store.createStep == .creating)
    }

    // Done starts the sheet's close; the key is dropped once it has closed
    // (the sheet's onDismiss)
    @Test func closingTheSheetDropsTheKey() throws {
        let (store, client, hops) = try showing()
        store.startCreate()
        store.create(name: "build bot")
        let created = ApiKeyCreatedItem(id: Self.newestKey, name: "build bot", apiKey: Self.secret)
        try client.answerCreate(.success(created))
        hops.run()

        store.dismissCreate()
        #expect(!store.createSheetPresented)
        // still drawn while the sheet slides away
        #expect(store.createStep == .created(created))

        store.closeCreate()
        #expect(store.createStep == nil)
        #expect(!store.createSheetPresented)
    }

    // a swipe on the name form closes it the same way: the binding, then
    // onDismiss
    @Test func swipingTheNameFormAwayDropsIt() throws {
        let (store, _, _) = try showing()
        store.startCreate()
        store.createSheetPresented = false
        store.closeCreate()
        #expect(store.createStep == nil)

        // the next sheet starts empty
        store.startCreate()
        #expect(store.createStep == .naming(failed: false))
    }

    // a create that answers after its sheet closed is shown to nobody, not
    // even a sheet opened since; the list loads, so the key can be deleted
    @Test func aCreateAnsweringAfterItsSheetClosedShowsNothing() throws {
        let (store, client, hops) = try showing()
        store.startCreate()
        store.create(name: "build bot")
        let lateCreate = try #require(client.creates.last)
        // the sheet went away anyway (the window closed)
        store.closeCreate()
        store.startCreate()

        lateCreate(.success(ApiKeyCreatedItem(id: Self.newestKey, name: "build bot", apiKey: Self.secret)))
        hops.run()
        #expect(store.createStep == .naming(failed: false))
        #expect(client.log == ["create build bot", "fetch"])
    }

    // the key is never printed, interpolated or dumped
    @Test func aCreatedKeyPrintsWithoutTheKey() {
        let created = ApiKeyCreatedItem(id: Self.newestKey, name: "build bot", apiKey: Self.secret)
        let step = ApiKeyCreateStep.created(created)
        var dumped = ""
        dump(step, to: &dumped)
        for text in [
            String(describing: created),
            String(reflecting: created),
            "\(created)",
            String(describing: step),
            String(reflecting: step),
            dumped,
        ] {
            #expect(!text.contains(Self.secret), "\(text)")
            #expect(!text.contains("urn_"), "\(text)")
        }
        #expect(String(describing: created).contains("build bot"))
    }

    // MARK: Delete

    @Test func deleteAsksBeforeAnythingIsDeleted() throws {
        let (store, client, _) = try showing()
        store.requestDelete(keyId: Self.olderKey)
        #expect(store.confirmation == ApiKeyDeleteConfirmation(keyId: Self.olderKey, name: "home server"))
        #expect(client.log.isEmpty)
    }

    // a key created through the API may have no name
    @Test func theConfirmationNamesAnUnnamedKey() throws {
        let (store, _, _) = try showing()
        store.requestDelete(keyId: Self.newerKey)
        #expect(store.confirmation == ApiKeyDeleteConfirmation(keyId: Self.newerKey, name: "Unnamed key"))
    }

    @Test func cancelDeletesNothing() throws {
        let (store, client, _) = try showing()
        store.requestDelete(keyId: Self.olderKey)
        store.cancelConfirmation()
        #expect(store.confirmation == nil)
        #expect(client.log.isEmpty)
        #expect(store.snapshot.deletes.isEmpty)
    }

    @Test func aKeyNoLongerListedIsNotAskedFor() throws {
        let (store, _, _) = try showing()
        store.requestDelete(keyId: Self.newestKey)
        #expect(store.confirmation == nil)
    }

    @Test func confirmingDeletesTheKey() throws {
        let (store, client, hops) = try showing()
        store.requestDelete(keyId: Self.olderKey)
        store.confirm(try #require(store.confirmation))
        #expect(store.confirmation == nil)
        #expect(client.log == ["remove \(Self.olderKey)"])
        #expect(store.snapshot.delete(for: Self.olderKey) == ApiKeyDeleteItem(keyId: Self.olderKey, deleting: true))

        try client.answerRemove(.success(()))
        hops.run()
        #expect(store.snapshot.keys == [Self.newer])
        #expect(store.snapshot.deletes.isEmpty)
        // nothing was loading, so nothing reloads
        #expect(client.log == ["remove \(Self.olderKey)"])
    }

    // a repeated activation while the key is deleting asks nothing and sends
    // nothing
    @Test func aKeyAlreadyDeletingIsNotAskedForAgain() throws {
        let (store, client, _) = try showing()
        store.requestDelete(keyId: Self.olderKey)
        let confirmation = try #require(store.confirmation)
        store.confirm(confirmation)
        store.requestDelete(keyId: Self.olderKey)
        #expect(store.confirmation == nil)
        // a second dialog's confirm, answered late
        store.confirm(confirmation)
        #expect(client.log == ["remove \(Self.olderKey)"])
    }

    @Test func aFailedDeleteStaysOnItsRowAndIsOfferedAgain() throws {
        let (store, client, hops) = try showing()
        store.requestDelete(keyId: Self.olderKey)
        store.confirm(try #require(store.confirmation))
        try client.answerRemove(.failure(ApiKeysRequestFailed()))
        hops.run()
        #expect(store.snapshot.keys == [Self.newer, Self.older])
        #expect(store.snapshot.delete(for: Self.olderKey) == ApiKeyDeleteItem(keyId: Self.olderKey, deleting: false, failed: true))

        store.requestDelete(keyId: Self.olderKey)
        store.confirm(try #require(store.confirmation))
        #expect(store.snapshot.delete(for: Self.olderKey) == ApiKeyDeleteItem(keyId: Self.olderKey, deleting: true))
        #expect(client.log == ["remove \(Self.olderKey)", "remove \(Self.olderKey)"])
    }

    // a load that read the list before the delete must not bring the key
    // back: a newer load replaces it
    @Test func aDeleteDuringALoadNeverBringsTheKeyBack() throws {
        let (store, client, hops) = try showing()
        store.requestDelete(keyId: Self.olderKey)
        store.confirm(try #require(store.confirmation))
        store.refresh()
        let staleLoad = try #require(client.fetches.last)

        try client.answerRemove(.success(()))
        hops.run()
        #expect(store.snapshot.keys == [Self.newer])
        #expect(client.log == ["remove \(Self.olderKey)", "fetch", "fetch"])

        staleLoad(.success([Self.older, Self.newer]))
        hops.run()
        #expect(store.snapshot.keys == [Self.newer])
        try client.answerFetch(.success([Self.newer]))
        hops.run()
        #expect(store.snapshot.keys == [Self.newer])
        #expect(!store.snapshot.loading)
    }

    // a failed delete's notice goes with its key
    @Test func aFailedDeleteOfAKeyNoLongerListedIsDropped() throws {
        let (store, client, hops) = try showing()
        store.requestDelete(keyId: Self.olderKey)
        store.confirm(try #require(store.confirmation))
        try client.answerRemove(.failure(ApiKeysRequestFailed()))
        hops.run()

        store.refresh()
        try client.answerFetch(.success([Self.newer]))
        hops.run()
        #expect(store.snapshot.deletes.isEmpty)
    }
}
