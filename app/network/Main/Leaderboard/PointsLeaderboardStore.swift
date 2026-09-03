//
//  PointsLeaderboardStore.swift
//  URnetwork
//

import Foundation
import SwiftUI
import URnetworkSdk

/**
 * One ranked network as the list renders it: a value copy of the sdk row
 * (the sdk re-emits fresh proxies on every event), with the preformatted
 * texts the sdk fills in. `displayName` is empty when the row is anonymous;
 * the screen then shows its localized "Anonymous". `emojiTag` shows either way.
 */
struct PointsLeaderboardRowItem: Identifiable, Equatable {
    let networkId: String
    let displayName: String
    let anonymous: Bool
    let emojiTag: String
    let totalPointsText: String
    let blocksWithPointsText: String
    let streakText: String
    let longestStreakText: String
    let rankPointsText: String
    let rankBlocksText: String
    let rankStreakText: String

    var id: String {
        networkId
    }

    init(_ row: SdkPointsLeaderboardRow) {
        networkId = row.networkId?.idStr ?? ""
        displayName = row.displayName
        anonymous = row.anonymous
        emojiTag = row.emojiTag
        totalPointsText = row.totalPointsText
        blocksWithPointsText = row.blocksWithPointsText
        streakText = row.streakText
        longestStreakText = row.longestStreakText
        rankPointsText = row.rankPointsText
        rankBlocksText = row.rankBlocksText
        rankStreakText = row.rankStreakText
    }
}

/// The caller's own row (always its own name) and its opt-in flag.
struct PointsLeaderboardMeItem: Equatable {
    let row: PointsLeaderboardRowItem?
    let isPublic: Bool
}

private class PointsLeaderboardListener: NSObject, SdkPointsLeaderboardListenerProtocol {
    private let callback: () -> Void

    init(callback: @escaping () -> Void) {
        self.callback = callback
    }

    func pointsLeaderboardChanged() {
        callback()
    }
}

/// completes with the error message, or nil on success
private class SetPointsPublicCallback: NSObject, SdkSetPointsLeaderboardPublicCallbackProtocol {
    private let completion: (String?) -> Void

    init(completion: @escaping (String?) -> Void) {
        self.completion = completion
    }

    func result(_ result: SdkSetPointsLeaderboardPublicResult?, err: Error?) {
        if let err {
            completion(err.localizedDescription)
        } else if let error = result?.error {
            completion(error.message)
        } else if result == nil {
            completion("set points leaderboard public: result is null")
        } else {
            completion(nil)
        }
    }
}

/// completes with the stored tag, or the error message
private class SetEmojiTagCallback: NSObject, SdkSetEmojiTagCallbackProtocol {
    private let completion: (Result<String, PointsLeaderboardActionError>) -> Void

    init(completion: @escaping (Result<String, PointsLeaderboardActionError>) -> Void) {
        self.completion = completion
    }

    func result(_ result: SdkSetEmojiTagResult?, err: Error?) {
        if let err {
            completion(.failure(.message(err.localizedDescription)))
        } else if let error = result?.error {
            completion(.failure(.message(error.message)))
        } else if let result {
            completion(.success(result.emojiTag))
        } else {
            completion(.failure(.message("set emoji tag: result is null")))
        }
    }
}

enum PointsLeaderboardActionError: Error {
    case message(String)

    var text: String {
        switch self {
        case .message(let message):
            return message
        }
    }
}

/**
 * The Points tab of the leaderboard. Every row, rank and page comes from the
 * sdk's PointsLeaderboardViewController (android/POINTSLEADERBOARD.md); this
 * only mirrors its state into SwiftUI and forwards the sort, load-more and
 * refresh intents. Opting in and the emoji tag go through the sdk api.
 */
@MainActor
class PointsLeaderboardStore: ObservableObject {
    @Published private(set) var rows: [PointsLeaderboardRowItem] = []
    @Published private(set) var sort: String = SdkPointsLeaderboardSortPoints
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var isEndReached: Bool = false
    /// the first page has landed (rows, an empty end, or an error)
    @Published private(set) var hasLoaded: Bool = false
    /// the controller's last request error; empty when the last page landed
    @Published private(set) var errorMessage: String = ""
    @Published private(set) var totalRanked: Int64 = 0
    @Published private(set) var latestEpoch: Int64 = 0
    @Published private(set) var me: PointsLeaderboardMeItem? = nil
    /// the network's opt-in, from `me` and updated locally on toggle
    @Published private(set) var isPointsPublic: Bool = false
    /// the network's emoji tag, from `me` and updated locally on save
    @Published private(set) var emojiTag: String = ""
    @Published private(set) var isSettingPublic: Bool = false
    @Published private(set) var isSavingEmojiTag: Bool = false
    /// a one-shot error from the opt-in toggle or the emoji save, for an alert
    @Published var actionError: String? = nil

    // the controller must be closed on the device that opened it, so the
    // owner is tracked across device changes (same discipline as the peers
    // and provider locations stores)
    private var device: SdkDeviceRemote?
    private var api: SdkApi?
    private var viewController: SdkPointsLeaderboardViewController?
    private var sub: SdkSubProtocol?

    // after a local toggle or save, `me` from an older in-flight page could
    // briefly disagree with what the user just did; the local values win
    // until a response newer than the edit lands
    private var ownFlagsEditedAt: UInt64 = 0
    private var ownFlagsAppliedAt: UInt64 = 0

    /**
     * Opens the controller on `device`. The same device keeps its controller;
     * a different one (or none) closes it and opens a new one.
     */
    func attach(device: SdkDeviceRemote?, api: SdkApi?) {
        self.api = api
        if let device, device === self.device, viewController != nil {
            return
        }
        detach()
        self.device = device
        guard let device else {
            return
        }
        let vc = device.openPointsLeaderboardViewController()
        self.viewController = vc
        self.sub = vc?.add(PointsLeaderboardListener { [weak self] in
            // the sdk calls from its own thread; state is read on main
            DispatchQueue.main.async {
                self?.readState()
            }
        })
        vc?.start()
        readState()
    }

    func detach() {
        sub?.close()
        sub = nil
        if let viewController {
            if let device {
                device.close(viewController)
            } else {
                viewController.close()
            }
        }
        viewController = nil
        device = nil
    }

    /**
     * Mirrors the controller into published state. Rows are compared by
     * value and only assigned when something changed, so a no-op event does
     * not re-render the whole list.
     */
    private func readState() {
        guard let vc = viewController else {
            return
        }
        var next: [PointsLeaderboardRowItem] = []
        if let list = vc.getRows() {
            for i in 0..<list.len() {
                if let row = list.get(i) {
                    next.append(PointsLeaderboardRowItem(row))
                }
            }
        }
        if next != rows {
            rows = next
        }
        let nextSort = vc.getSort()
        if nextSort != sort {
            sort = nextSort
        }
        let loading = vc.isLoading()
        if loading != isLoading {
            isLoading = loading
        }
        let end = vc.isEndReached()
        if end != isEndReached {
            isEndReached = end
        }
        let error = vc.getErrorMessage()
        if error != errorMessage {
            errorMessage = error
        }
        let ranked = vc.getTotalRanked()
        if ranked != totalRanked {
            totalRanked = ranked
        }
        let epoch = vc.getLatestEpoch()
        if epoch != latestEpoch {
            latestEpoch = epoch
        }
        let meItem = vc.getMe().map { me in
            PointsLeaderboardMeItem(
                row: me.row.map { PointsLeaderboardRowItem($0) },
                isPublic: me.pointsLeaderboardPublic
            )
        }
        if meItem != me {
            me = meItem
        }
        if let meItem, ownFlagsAppliedAt >= ownFlagsEditedAt {
            if meItem.isPublic != isPointsPublic {
                isPointsPublic = meItem.isPublic
            }
            let tag = meItem.row?.emojiTag ?? ""
            if tag != emojiTag {
                emojiTag = tag
            }
        }
        if !loading && (!next.isEmpty || end || !error.isEmpty) && !hasLoaded {
            hasLoaded = true
        }
    }

    /// Switches the sort; the controller clears its rows and reloads.
    func selectSort(_ sort: String) {
        if sort == self.sort || !SdkIsPointsLeaderboardSort(sort) {
            return
        }
        // reflect the chip immediately; the controller confirms on its event
        self.sort = sort
        viewController?.setSort(sort)
    }

    func loadMore() {
        viewController?.loadMore()
    }

    func refresh() {
        // the next `me` that lands is newer than any local edit
        ownFlagsAppliedAt = DispatchTime.now().uptimeNanoseconds
        viewController?.refresh()
    }

    /// Retries after an error: the controller re-requests the same page.
    func retry() {
        if rows.isEmpty {
            refresh()
        } else {
            loadMore()
        }
    }

    func togglePointsPublic() {
        if isSettingPublic {
            return
        }
        guard let api else {
            actionError = "Device or API is null"
            return
        }
        let target = !isPointsPublic
        isSettingPublic = true
        let args = SdkSetPointsLeaderboardPublicArgs()
        args.`public` = target
        api.setPointsLeaderboardPublic(args, callback: SetPointsPublicCallback { [weak self] error in
            DispatchQueue.main.async {
                guard let self else {
                    return
                }
                if let error {
                    self.actionError = error
                } else {
                    self.ownFlagsEditedAt = DispatchTime.now().uptimeNanoseconds
                    self.isPointsPublic = target
                    // the list shows or hides the own row; `me` is re-read too
                    self.refresh()
                }
                self.isSettingPublic = false
            }
        })
    }

    /**
     * Stores the tag (already normalized by `SdkValidateEmojiTag`), or an
     * empty string to clear it. `onDone` gets the server's message on failure.
     */
    func saveEmojiTag(_ tag: String, onDone: @escaping (String?) -> Void) {
        if isSavingEmojiTag {
            return
        }
        guard let api else {
            onDone("Device or API is null")
            return
        }
        isSavingEmojiTag = true
        let args = SdkSetEmojiTagArgs()
        args.emojiTag = tag
        api.setEmojiTag(args, callback: SetEmojiTagCallback { [weak self] result in
            DispatchQueue.main.async {
                guard let self else {
                    return
                }
                switch result {
                case .success(let stored):
                    self.ownFlagsEditedAt = DispatchTime.now().uptimeNanoseconds
                    self.emojiTag = stored
                    self.refresh()
                    onDone(nil)
                case .failure(let error):
                    onDone(error.text)
                }
                self.isSavingEmojiTag = false
            }
        })
    }
}
