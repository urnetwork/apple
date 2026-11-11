//
//  ProFeaturesNotice.swift
//  URnetwork
//
//  The network's Pro features in use, as the app shows them: its hosted
//  proxies hold SOCKS or WireGuard, the two proxy features that are part of
//  Pro, and the network has no Pro (owner decision 2026-11-11). Before the
//  server enforces that, an upgrade keeps them working; after, they stopped,
//  and an upgrade turns them back on. The main screen shows a notice the user
//  can close, and the device list, which lists the proxies, says the same.
//
//  The sdk decides all of it (pro_features_status.go): the prompt, from the
//  server's live plan and each proxy's features, and when the main screen's
//  notice shows (ProFeaturesNoticeTracker). Its ProFeaturesViewController
//  reads the network's proxies with the network credential the api keeps;
//  ProFeaturesNoticeStore opens one for each sign-in and mirrors its
//  snapshots on the main actor. This file holds only the words and that
//  mirror. There is no local notification: the notice is on the app's own
//  screens.
//

import Foundation
import URnetworkSdk

/// What a Pro features notice says (the sdk's ProFeaturesStatus.prompt).
enum ProFeaturesPrompt: Equatable {
    /// SdkProFeaturesPromptUpgrade, before enforcement: SOCKS and WireGuard
    /// proxies are part of Pro, and an upgrade keeps them working
    case upgrade
    /// SdkProFeaturesPromptStopped, after enforcement: they stopped working
    /// on the network's proxies, and an upgrade turns them back on
    case stopped

    /// Nil for SdkProFeaturesPromptNone: nothing to say.
    init?(_ prompt: String) {
        switch prompt {
        case SdkProFeaturesPromptUpgrade:
            self = .upgrade
        case SdkProFeaturesPromptStopped:
            self = .stopped
        default:
            return nil
        }
    }

    var title: String {
        switch self {
        case .upgrade:
            return String(localized: "Pro features in use")
        case .stopped:
            return String(localized: "SOCKS and WireGuard stopped working")
        }
    }

    var body: String {
        switch self {
        case .upgrade:
            return String(localized: "SOCKS and WireGuard proxies are part of Pro. Upgrade to keep using them.")
        case .stopped:
            return String(localized: "SOCKS and WireGuard are part of Pro, so they no longer work on your proxies. HTTP and HTTPS still work. Upgrade to turn them back on. WireGuard can take up to 30 minutes to reconnect.")
        }
    }
}

/**
 * The main screen's Pro features notice: the sdk's ProFeaturesViewController
 * of the signed-in account, its snapshots mirrored on the main actor.
 *
 * One controller per sign-in, opened on the account api (it needs no
 * device): its tracker shows the notice once per sign-in and keeps the
 * user's close while the prompt stays the same. NetworkApp follows the
 * device with it: a new device (a sign-in, or the launch of a signed-in app)
 * opens and starts one, and a sign out or another account closes it, which
 * ends its notice, so the next sign-in starts afresh. NetworkApp refreshes it
 * when the app comes to the front and when the plan changes, and the screens
 * that show the device list refresh it once the list closes, since a removal
 * can take the last SOCKS or WireGuard proxy. The controller reads the list
 * again every hour while open.
 *
 * Its calls take no device lock (the controller is the api's), so they run
 * on the main actor. A listener's hop reads the controller's newest snapshot,
 * not the one it was handed, so a late delivery never replaces a newer one,
 * and a hop for a closed controller changes nothing.
 */
@MainActor
final class ProFeaturesNoticeStore: ObservableObject {

    /// what the main screen shows; nil without a notice (no prompt, the user
    /// closed it, or no one is signed in)
    @Published private(set) var mainPrompt: ProFeaturesPrompt? = nil

    private var controller: SdkProFeaturesViewController?
    private var listenerSub: SdkSubProtocol?
    // the device of the sign-in the controller is for, by identity: the
    // device manager makes one device per sign-in (and one at the launch of
    // a signed-in app), while the api is the network space's, the same from
    // one account to the next. Held only to tell one sign-in from the next,
    // and let go at the sign out
    private var device: SdkDeviceRemote?
    // each close advances it, so a hop for a closed controller is dropped
    private var generation = 0

    /// The signed-in device changed: a device opens a controller on `api`
    /// and starts it; none (a sign out) or another one (another account)
    /// closes the one open first.
    func follow(api: SdkApi?, device: SdkDeviceRemote?) {
        guard device !== self.device else {
            return
        }
        close()
        self.device = device
        guard device != nil, let api, let controller = api.openProFeaturesViewController() else {
            return
        }
        self.controller = controller
        let generation = self.generation
        listenerSub = controller.add(ProFeaturesListener { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.update(generation: generation)
                }
            }
        })
        controller.start()
        update(generation: generation)
    }

    /// Reads the network's proxies again.
    func refresh() {
        controller?.refresh()
    }

    /// The user closed the main screen's notice: it stays withdrawn while
    /// its prompt stays the same (the sdk decides). The device list goes on
    /// showing the prompt.
    func dismissMainNotice() {
        controller?.dismissMainNotice()
        update(generation: generation)
    }

    /// Drops the listener, then closes the controller, and the notice with it.
    private func close() {
        generation += 1
        listenerSub?.close()
        listenerSub = nil
        controller?.close()
        controller = nil
        if mainPrompt != nil {
            mainPrompt = nil
        }
    }

    private func update(generation: Int) {
        guard generation == self.generation, let controller else {
            return
        }
        let next = ProFeaturesPrompt(controller.getSnapshot()?.mainPrompt ?? "")
        if next != mainPrompt {
            mainPrompt = next
        }
    }
}

/// The controller's listener, calling a closure on an sdk thread.
private final class ProFeaturesListener: NSObject, SdkProFeaturesListenerProtocol {
    private let callback: @Sendable () -> Void

    init(_ callback: @escaping @Sendable () -> Void) {
        self.callback = callback
    }

    func proFeaturesChanged(_ snapshot: SdkProFeaturesSnapshot?) {
        callback()
    }
}
