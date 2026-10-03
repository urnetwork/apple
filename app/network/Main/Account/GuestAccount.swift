//
//  GuestAccount.swift
//  URnetwork
//

import Foundation

/**
 * Legacy guest networks (finding A4 in server/UPGRADE.md §3).
 *
 * The server no longer creates guest networks, but a jwt minted before July
 * can still carry `guest_mode` until its first refresh. Such a network can hold
 * a plan and a balance: a guest could buy Pro. "Create an account" used to run
 * the login flow and sign in to a NEW network, which left the paid plan and
 * balance behind on the guest network with no way back to it.
 *
 * A guest now converts in place: it adds a sign-in method to its own network
 * (the server's AddAuth, which checks live auth methods, so the network stops
 * being a bare guest the moment the method exists), then re-signs the jwt so
 * `guest_mode` clears. The network, its plan and its balance stay. Nothing logs
 * out.
 */
enum GuestAccount {

    /**
     * Whether the session is a legacy guest. No jwt is not a guest: a missing
     * claim used to read as guest, which offered the guest-only flows to a
     * session that had not loaded yet.
     */
    static func isGuest(guestModeClaim: Bool?) -> Bool {
        guestModeClaim ?? false
    }
}

/**
 * The session a conversion runs on. `logout` is here so the contract is
 * explicit: the conversion never logs out (that is what stranded the balance).
 */
@MainActor
protocol GuestAccountSession: AnyObject {
    func refreshJwt()
    func logout()
}

/**
 * Completes the in-place conversion once a sign-in method was added to the
 * guest's own network.
 */
@MainActor
struct GuestAccountConversion {

    let session: GuestAccountSession

    /**
     * Re-sign the jwt so `guest_mode` clears (the refresh signs a non-guest
     * jwt for the same network). The session stays on this network.
     */
    func signInMethodAdded() {
        session.refreshJwt()
    }
}

/// The app's session: the device re-signs the jwt for the same network.
@MainActor
final class DeviceGuestAccountSession: GuestAccountSession {

    private weak var deviceManager: DeviceManager?
    private let logoutAction: () -> Void

    init(deviceManager: DeviceManager, logout: @escaping () -> Void) {
        self.deviceManager = deviceManager
        self.logoutAction = logout
    }

    func refreshJwt() {
        do {
            try deviceManager?.device?.refreshToken(0)
        } catch {
            print("[GuestAccount] error refreshing the jwt: \(error)")
        }
    }

    func logout() {
        logoutAction()
    }
}
