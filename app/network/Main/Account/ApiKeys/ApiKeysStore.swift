//
//  ApiKeysStore.swift
//  URnetwork
//
//  Account > API keys (owner decision 2026-10-29): the network's API keys,
//  each created from a name and deleted after a confirmation, on the account
//  api (Api.ListApiKeys, Api.CreateApiKey, Api.DeleteApiKey). There is no SDK
//  controller for keys, so this store owns the list and its loads, the create
//  sheet's steps and each delete; the client only runs the requests.
//
//  A created key is the one secret here. The store holds it for the created
//  step of the sheet only, and drops it once the sheet has closed. It is
//  never written anywhere, logged or reported, and the value that carries it
//  prints and dumps without it.
//
//  Everything here runs on the main actor. The client answers on an SDK
//  thread, and each answer hops to the main queue before it touches the
//  store. An answer to a load that a newer load replaced, or any answer that
//  lands after the store closed, changes nothing.
//

import Foundation
import URnetworkSdk

// MARK: Values

/// One of the network's API keys. The server keeps only a hash of the key
/// itself, so the list never has it.
struct ApiKeyItem: Equatable, Identifiable {
    /// the key's id, which a delete sends
    let id: String
    /// empty for a key created without one (through the API)
    var name: String = ""
    /// unix milliseconds; nil when the server sent none
    var createTimeMillis: Int64? = nil
}

/// A key just created: the only time its secret is known.
struct ApiKeyCreatedItem: Equatable {
    let id: String
    let name: String
    /// the `urn_…` key, shown once
    let apiKey: String
}

/// Printing, interpolating or dumping a created key leaves the key out.
extension ApiKeyCreatedItem: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {

    var description: String {
        "ApiKeyCreatedItem(id: \(id), name: \(name), apiKey: <redacted>)"
    }

    var debugDescription: String {
        description
    }

    var customMirror: Mirror {
        Mirror(self, children: ["id": id, "name": name], displayStyle: .struct)
    }
}

/// What the screen shows in place of the list, or the list itself.
enum ApiKeysContent: Equatable {
    /// never loaded
    case loading
    /// the first load failed
    case loadFailed
    /// loaded with no keys
    case empty
    case list
}

/// A delete in flight, or the last one that failed, of one key.
struct ApiKeyDeleteItem: Equatable {
    let keyId: String
    /// the request is in flight: the row shows progress and offers no delete
    var deleting: Bool = false
    /// the last delete failed; the row says so and offers it again
    var failed: Bool = false
}

/// One read of the list.
struct ApiKeysSnapshot: Equatable {
    /// newest first (ApiKeyOrder)
    var keys: [ApiKeyItem] = []
    /// a load has succeeded
    var loaded: Bool = false
    /// a load is in flight: the first one, or a refresh
    var loading: Bool = false
    /// the last load failed, and none is in flight
    var loadFailed: Bool = false
    var deletes: [ApiKeyDeleteItem] = []

    var content: ApiKeysContent {
        if !loaded {
            // a retry after a failed first load shows progress again
            return loadFailed ? .loadFailed : .loading
        }
        return keys.isEmpty ? .empty : .list
    }

    /// A load after the list was shown is in flight; the rows stay.
    var refreshing: Bool {
        loaded && loading
    }

    /// A load after the list was shown failed: the rows stay, with a
    /// non-blocking notice.
    var refreshFailed: Bool {
        loaded && loadFailed
    }

    func delete(for keyId: String) -> ApiKeyDeleteItem? {
        deletes.first { $0.keyId == keyId }
    }
}

/// The create sheet's step.
enum ApiKeyCreateStep: Equatable {
    /// the name form; `failed` once a create failed, with the name kept for
    /// another try
    case naming(failed: Bool)
    /// the request is in flight; the sheet does not close
    case creating
    /// the new key, shown once
    case created(ApiKeyCreatedItem)
}

/// A delete waiting for the user's answer.
struct ApiKeyDeleteConfirmation: Equatable {
    let keyId: String
    /// the key as the list names it (ApiKeyLabels.name)
    let name: String
}

// MARK: Client

/// A request that failed. Its cause is never shown or kept: the screen says
/// which action failed, in its own words.
struct ApiKeysRequestFailed: Error, Equatable {}

/// The account api as the store drives it. A protocol so the tests stand in
/// for the SDK. Each request answers exactly once, on any thread.
protocol ApiKeysClient: AnyObject {
    /// `GET /account/api-keys`, in the server's order
    func fetchApiKeys(_ done: @escaping @Sendable (Result<[ApiKeyItem], ApiKeysRequestFailed>) -> Void)
    /// `POST /account/api-key`
    func createApiKey(named name: String, _ done: @escaping @Sendable (Result<ApiKeyCreatedItem, ApiKeysRequestFailed>) -> Void)
    /// `POST /account/api-key/remove`. An id the network has no key for
    /// deletes nothing and succeeds.
    func removeApiKey(id: String, _ done: @escaping @Sendable (Result<Void, ApiKeysRequestFailed>) -> Void)
}

// MARK: Store

/**
 * Publishes the network's API keys for Account > API keys.
 *
 * Loads: the list loads the first time the screen is visible (on screen and
 * the app presenting, the lifecycle the rest of the app uses), each time it
 * becomes visible again, after every create, and on refresh. Each load is
 * numbered and only the newest one's answer lands, so a slow answer never
 * replaces a newer list; a delete that succeeds while a load is in flight
 * starts a newer one, since the one in flight may still list the key.
 *
 * Create: the sheet is presented (`createSheetPresented`) with the name
 * form, sends the trimmed name once, and on success shows the key until the
 * sheet closes. `dismissCreate` only starts the sheet's close; `closeCreate`,
 * which the sheet's onDismiss calls, drops the name form's state and the
 * key. A create that answers after its sheet closed is shown to nobody; the
 * list loads either way, so the new key is listed and can be deleted.
 *
 * Delete: every delete waits for a confirmation naming the key. A key
 * already deleting is not asked for again; a failed delete stays on its row
 * and is offered again.
 */
@MainActor
final class ApiKeysStore: ObservableObject {

    @Published private(set) var snapshot = ApiKeysSnapshot()
    /// the create sheet's step; nil while no sheet is open
    @Published private(set) var createStep: ApiKeyCreateStep? = nil
    /// the create sheet is presented; the sheet's binding sets it false when
    /// the user swipes it away
    @Published var createSheetPresented = false
    /// the delete waiting for the user's answer
    @Published private(set) var confirmation: ApiKeyDeleteConfirmation? = nil

    /// Runs `work` on the main actor later. Tests pass a queue they drain.
    typealias Dispatch = (@escaping @MainActor () -> Void) -> Void

    nonisolated static func dispatchOnMainQueue(_ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                work()
            }
        }
    }

    private let client: ApiKeysClient
    private let dispatch: Dispatch
    private var closed = false

    private var onScreen = false
    private var presentationActive = false
    private var visible = false

    // the newest load's number; an answer to any other changes nothing
    private var loadGeneration: UInt64 = 0
    // the open sheet's number; a create answers only the sheet that sent it
    private var createGeneration: UInt64 = 0
    // pulls to refresh, waiting for the newest load to finish
    private var refreshWaiters: [CheckedContinuation<Void, Never>] = []

    init(client: ApiKeysClient, dispatch: @escaping Dispatch = ApiKeysStore.dispatchOnMainQueue) {
        self.client = client
        self.dispatch = dispatch
    }

    // MARK: Lifecycle

    /// The screen appeared or disappeared.
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

    /// Final: nothing loads or lands after it, and the sheet's key is gone.
    func close() {
        guard !closed else {
            return
        }
        closed = true
        visible = false
        createStep = nil
        createSheetPresented = false
        confirmation = nil
        resumeRefreshWaiters()
    }

    private func updateVisible() {
        let nextVisible = !closed && onScreen && presentationActive
        guard nextVisible != visible else {
            return
        }
        visible = nextVisible
        if nextVisible {
            load()
        }
    }

    // MARK: Loads

    /// Starts a load that replaces any in flight.
    private func load() {
        guard !closed else {
            return
        }
        loadGeneration += 1
        let generation = loadGeneration
        snapshot.loading = true
        snapshot.loadFailed = false
        let dispatch = self.dispatch
        client.fetchApiKeys { [weak self] result in
            dispatch {
                self?.loaded(result, generation: generation)
            }
        }
    }

    private func loaded(_ result: Result<[ApiKeyItem], ApiKeysRequestFailed>, generation: UInt64) {
        // the screen is gone, or a newer load replaced this one
        guard !closed, generation == loadGeneration else {
            return
        }
        snapshot.loading = false
        switch result {
        case .success(let keys):
            snapshot.keys = ApiKeyOrder.sorted(keys)
            snapshot.loaded = true
            // a failed delete is kept only while its key is listed
            snapshot.deletes.removeAll { delete in
                !delete.deleting && !keys.contains { $0.id == delete.keyId }
            }
        case .failure:
            snapshot.loadFailed = true
        }
        resumeRefreshWaiters()
    }

    // MARK: Intents

    /// The toolbar refresh or Try again.
    func refresh() {
        load()
    }

    /**
     * A pull: refreshes, then returns once the newest load has finished, so
     * the pull indicator stays until the list has landed. Returns at once
     * when the store is closed, and when it closes.
     */
    func refreshAndWait() async {
        guard !closed else {
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // waiting before the load starts, so no answer can come first
            refreshWaiters.append(continuation)
            load()
        }
    }

    private func resumeRefreshWaiters() {
        let waiters = refreshWaiters
        refreshWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// Create: opens the sheet on its name form.
    func startCreate() {
        guard !closed, createStep == nil else {
            return
        }
        createGeneration += 1
        createStep = .naming(failed: false)
        createSheetPresented = true
    }

    /**
     * The sheet's Create: sends the name, trimmed. Nothing happens for a name
     * with nothing left (ApiKeyName), or while a create is in flight.
     */
    func create(name: String) {
        guard !closed, case .naming = createStep, let name = ApiKeyName.normalized(name) else {
            return
        }
        createStep = .creating
        let generation = createGeneration
        let dispatch = self.dispatch
        client.createApiKey(named: name) { [weak self] result in
            dispatch {
                self?.created(result, generation: generation)
            }
        }
    }

    private func created(_ result: Result<ApiKeyCreatedItem, ApiKeysRequestFailed>, generation: UInt64) {
        guard !closed else {
            return
        }
        // the key is listed either way, and a failure may still have created
        // one (an answer lost after the server's commit)
        load()
        // the sheet that sent it has closed: the key is shown to nobody
        guard generation == createGeneration, createStep == .creating else {
            return
        }
        switch result {
        case .success(let created):
            createStep = .created(created)
        case .failure:
            createStep = .naming(failed: true)
        }
    }

    /// Cancel or Done: starts the sheet's close. Nothing closes while a
    /// create is in flight.
    func dismissCreate() {
        guard createStep != .creating else {
            return
        }
        createSheetPresented = false
    }

    /// The sheet has closed, however it closed: drops the name form's state
    /// and the key.
    func closeCreate() {
        createStep = nil
        createSheetPresented = false
    }

    /**
     * A row's Delete: asks first. Nothing happens for a key already deleting
     * (a repeated activation), or one no longer listed.
     */
    func requestDelete(keyId: String) {
        guard !closed,
              let key = snapshot.keys.first(where: { $0.id == keyId }),
              !(snapshot.delete(for: keyId)?.deleting ?? false) else {
            return
        }
        confirmation = ApiKeyDeleteConfirmation(keyId: keyId, name: ApiKeyLabels.name(key))
    }

    /// The user confirmed `confirmation` (the dialog hands back the one it
    /// presented). The row shows the delete at once.
    func confirm(_ confirmation: ApiKeyDeleteConfirmation) {
        self.confirmation = nil
        let keyId = confirmation.keyId
        guard !closed, !(snapshot.delete(for: keyId)?.deleting ?? false) else {
            return
        }
        setDelete(ApiKeyDeleteItem(keyId: keyId, deleting: true))
        let dispatch = self.dispatch
        client.removeApiKey(id: keyId) { [weak self] result in
            dispatch {
                self?.deleted(keyId: keyId, result)
            }
        }
    }

    /// Cancel, the default: nothing is deleted.
    func cancelConfirmation() {
        confirmation = nil
    }

    private func deleted(keyId: String, _ result: Result<Void, ApiKeysRequestFailed>) {
        guard !closed else {
            return
        }
        switch result {
        case .success:
            snapshot.deletes.removeAll { $0.keyId == keyId }
            snapshot.keys.removeAll { $0.id == keyId }
            // the load in flight may have read the list before the delete
            if snapshot.loading {
                load()
            }
        case .failure:
            setDelete(ApiKeyDeleteItem(keyId: keyId, deleting: false, failed: true))
        }
    }

    private func setDelete(_ delete: ApiKeyDeleteItem) {
        if let i = snapshot.deletes.firstIndex(where: { $0.keyId == delete.keyId }) {
            snapshot.deletes[i] = delete
        } else {
            snapshot.deletes.append(delete)
        }
    }
}

// MARK: SDK

/// The SDK's answers as the store takes them. A request error, a result
/// error, or a result without what the screen needs is a failure, and the
/// server's message is never kept.
enum ApiKeysAnswers {

    /// The listed keys, in the server's order. A list with no keys comes
    /// back as none at all. A key without an id cannot be deleted, so it is
    /// not listed.
    static func list(_ result: SdkListApiKeysResult?, err: Error?) -> Result<[ApiKeyItem], ApiKeysRequestFailed> {
        guard err == nil, let result, result.error == nil else {
            return .failure(ApiKeysRequestFailed())
        }
        var keys: [ApiKeyItem] = []
        if let list = result.apiKeys {
            keys.reserveCapacity(list.len())
            for i in 0..<list.len() {
                if let key = list.get(i), let keyId = key.id_?.idStr, !keyId.isEmpty {
                    keys.append(ApiKeyItem(
                        id: keyId,
                        name: key.name,
                        createTimeMillis: key.createTime?.unixMilli()
                    ))
                }
            }
        }
        return .success(keys)
    }

    /// The new key; a result without the key or its id is a failure.
    static func created(_ result: SdkCreateApiKeyResult?, err: Error?) -> Result<ApiKeyCreatedItem, ApiKeysRequestFailed> {
        guard err == nil, let result, result.error == nil,
              let keyId = result.id_?.idStr, !keyId.isEmpty,
              !result.apiKey.isEmpty else {
            return .failure(ApiKeysRequestFailed())
        }
        return .success(ApiKeyCreatedItem(id: keyId, name: result.name, apiKey: result.apiKey))
    }

    static func deleted(_ result: SdkDeleteApiKeyResult?, err: Error?) -> Result<Void, ApiKeysRequestFailed> {
        guard err == nil, let result, result.error == nil else {
            return .failure(ApiKeysRequestFailed())
        }
        return .success(())
    }
}

extension SdkApi: ApiKeysClient {

    func fetchApiKeys(_ done: @escaping @Sendable (Result<[ApiKeyItem], ApiKeysRequestFailed>) -> Void) {
        listApiKeys(ListApiKeysCallback { result, err in
            done(ApiKeysAnswers.list(result, err: err))
        })
    }

    func createApiKey(named name: String, _ done: @escaping @Sendable (Result<ApiKeyCreatedItem, ApiKeysRequestFailed>) -> Void) {
        let args = SdkCreateApiKeyArgs()
        args.name = name
        createApiKey(args, callback: CreateApiKeyCallback { result, err in
            done(ApiKeysAnswers.created(result, err: err))
        })
    }

    func removeApiKey(id: String, _ done: @escaping @Sendable (Result<Void, ApiKeysRequestFailed>) -> Void) {
        var parseError: NSError?
        guard let keyId = SdkParseId(id, &parseError), parseError == nil else {
            done(.failure(ApiKeysRequestFailed()))
            return
        }
        let args = SdkDeleteApiKeyArgs()
        args.id_ = keyId
        // Api.DeleteApiKey, which Swift imports as deleteKey
        deleteKey(args, callback: DeleteApiKeyCallback { result, err in
            done(ApiKeysAnswers.deleted(result, err: err))
        })
    }
}

private class ListApiKeysCallback: OneShotSdkCallback<SdkListApiKeysResult, SdkListApiKeysCallbackProtocol>, SdkListApiKeysCallbackProtocol {
    func result(_ result: SdkListApiKeysResult?, err: Error?) {
        handleResult(result, err: err)
    }
}

private class CreateApiKeyCallback: OneShotSdkCallback<SdkCreateApiKeyResult, SdkCreateApiKeyCallbackProtocol>, SdkCreateApiKeyCallbackProtocol {
    func result(_ result: SdkCreateApiKeyResult?, err: Error?) {
        handleResult(result, err: err)
    }
}

private class DeleteApiKeyCallback: OneShotSdkCallback<SdkDeleteApiKeyResult, SdkDeleteApiKeyCallbackProtocol>, SdkDeleteApiKeyCallbackProtocol {
    func result(_ result: SdkDeleteApiKeyResult?, err: Error?) {
        handleResult(result, err: err)
    }
}
