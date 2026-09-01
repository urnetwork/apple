//
//  LogVerbosityState.swift
//  URnetwork
//
//  The log verbosity the device reports, and the one write path that changes
//  it.
//
//  Everything here goes through the DEVICE, never `SdkSetLogVerbosity`. That
//  function sets the calling process only, and on iOS the transport, the
//  contracts and the window all run in the packet tunnel extension -- a
//  separate process with its own glog state. Raising the app process's level
//  would leave the user watching a control that changes nothing in the bundle,
//  which is the same trap FlushGlog hit. `SdkDeviceRemote.setLogVerbosity`
//  raises this process AND carries the level to the extension, over the rpc
//  when the tunnel is up and on the next sync when it is not.
//
//  Held outside the view, like the export state, so an in-flight change is not
//  abandoned by navigating away mid-rpc.
//

import Foundation
import URnetworkSdk

final class LogVerbosityState: ObservableObject {

    static let shared = LogVerbosityState()

    /**
     * The level the device reports, never the one that was requested, and
     * `nil` when there is no device to ask.
     *
     * Every write re-reads, and the UI renders this -- so a level that was
     * clamped, refused, or never applied shows as the level actually in force
     * instead of the one the user tapped. A control that silently assumes its
     * own value is how a bundle ends up captured at 0 by someone who believes
     * they are at 2.
     *
     * `nil` is a distinct state from 0, not a stand-in for it. Defaulting to
     * `LogVerbosity.minimum` made the row read "0 · Default" whenever no
     * device had been asked, which is precisely the local guess the read-back
     * exists to prevent: the contract and transport logging is produced by
     * the packet tunnel extension, so with no device the app process knows
     * nothing about the level in force there -- it may be anything, or the
     * extension may never have received the setting at all. Matches Android's
     * `DeveloperViewModel.logVerbosity`.
     *
     * `SdkDeviceRemote.getLogVerbosity` answers from this process rather than
     * over the rpc, deliberately: the two levels are set together, so the
     * local answer is the level that was chosen, and it stays answerable while
     * the tunnel is down -- which is exactly when a user is deciding what the
     * next session will capture.
     */
    @Published private(set) var level: Int?

    /// True across a write. The write is an rpc round trip into the
    /// extension, so the stepper is held rather than allowed to queue a
    /// second one behind it.
    @Published private(set) var isApplying = false

    /// Republishes what the device reports, or clears the level when there is
    /// no device -- rather than leaving whatever was last read standing, which
    /// would keep a level on screen after the device it was read from is gone.
    @MainActor
    func refresh(device: SdkDeviceRemote?) async {
        guard let device else {
            level = nil
            return
        }
        level = await Self.read(device)
    }

    /**
     * Applies a level and republishes what the device then reports.
     *
     * The call is a synchronous rpc into the packet tunnel extension, so it
     * runs off the main actor -- the same rule every other device call on the
     * developer screen follows. `device` is read on the main actor before the
     * hop.
     */
    @MainActor
    func setLevel(_ newLevel: Int, device: SdkDeviceRemote?) async {
        guard !isApplying else { return }
        // nothing to write to and nothing to read back from: the row goes to
        // unavailable rather than reporting a level nobody confirmed
        guard let device else {
            level = nil
            return
        }
        let clamped = LogVerbosity.clamp(newLevel)

        isApplying = true
        await Task.detached(priority: .userInitiated) {
            device.setLogVerbosity(clamped)
        }.value
        isApplying = false

        level = await Self.read(device)
    }

    /// A flag read through cgo. Cheap, but still not main-actor work: a cgo
    /// hop can block on a Go GC stop-the-world.
    private static func read(_ device: SdkDeviceRemote) async -> Int {
        await Task.detached(priority: .userInitiated) {
            device.getLogVerbosity()
        }.value
    }
}
