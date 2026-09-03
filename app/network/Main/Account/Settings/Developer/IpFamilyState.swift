//
//  IpFamilyState.swift
//  URnetwork
//
//  The control-plane address family policy in force, and the one write path
//  that changes it.
//
//  DELIBERATELY UNLIKE LogVerbosityState, which routes everything through the
//  device and goes inert when there is none. This setting has to work with no
//  device and with the tunnel down, because those are the states a user is in
//  when the api is unreachable -- which is the whole reason to reach for it.
//  So the write is a THREE-way fallback, the same one android's
//  DeveloperViewModel uses: the device when there is one (on ios that is what
//  carries the policy into the packet tunnel extension, the process that dials
//  while the tunnel is up); else the network space (which sets this process
//  and records the choice for the next launch); else the process-global
//  SdkSetControlIpFamilyPolicy, which records nothing but at least puts the
//  choice in force for the session.
//
//  Held outside the view so an in-flight change is not abandoned by navigating
//  away mid-rpc.
//

import Foundation
import URnetworkSdk

final class IpFamilyState: ObservableObject {

    static let shared = IpFamilyState()

    /// The policy this process reports. Never a learned demotion -- that is
    /// `status` -- so the row round-trips exactly what was set and Automatic
    /// always reads back as Automatic.
    @Published private(set) var policy: Int = IpFamily.auto

    /// What the sdk has learned on its own, empty when nothing is demoted.
    /// Rendered in the detail line so Automatic does not look identical
    /// whether the heuristic has fired or not.
    ///
    /// Read from the DEVICE when there is one, unlike `policy`, which either
    /// process can answer. A demotion is not set, it is LEARNED in whichever
    /// process made the dial that failed, and while the tunnel is up that is
    /// the network extension. Asking this process there would report an empty
    /// string with a demotion actively in force -- exactly the ambiguity the
    /// detail line exists to remove.
    @Published private(set) var status: String = ""

    /// True across a write AND the read-back that follows it, as one unit.
    /// With a device the write is an rpc round trip into the extension, so the
    /// row is held rather than allowed to queue a second tap behind it.
    @Published private(set) var isApplying = false

    @MainActor
    func refresh(device: SdkDeviceRemote?) async {
        let read = await Task.detached(priority: .userInitiated) {
            (
                policy: device?.getControlIpFamilyPolicy() ?? Int(SdkGetControlIpFamilyPolicy()),
                // an rpc round trip into the dialing process. The
                // process-global is the right answer only when there is no
                // device, because then THIS process is the one dialing --
                // see DeviceRemote.GetControlIpFamilyStatus, which falls
                // back the same way and for the same reason
                status: device?.getControlIpFamilyStatus() ?? SdkGetControlIpFamilyStatus()
            )
        }.value
        policy = IpFamily.clamp(read.policy)
        status = read.status
    }

    /**
     * Advances to the next policy and republishes what the sdk then reports.
     *
     * Three write paths, tried in order, matching android exactly:
     *
     * 1. the device, when there is one -- it sets this process, records the
     *    choice, AND carries the policy across to the extension, so it is
     *    always preferred;
     * 2. `networkSpace`, which is what makes this work signed out or with the
     *    tunnel down: it sets this process and persists the choice;
     * 3. the process-global setter, when there is neither -- nothing records
     *    it, but the session at least dials under what the row shows.
     *
     * `networkSpace` comes from `DeviceManager.networkSpace`
     * (`DeviceManager.swift:60`), which is an independent `@Published`
     * property and is NOT derived from `device`. Android's is
     * (`DeviceManager.kt:54` is `device?.networkSpace`), which is why that
     * platform fetches the space from `NetworkSpaceManagerProvider` instead.
     * The two reach the same three-way behaviour by different routes.
     */
    @MainActor
    func cycle(device: SdkDeviceRemote?, networkSpace: SdkNetworkSpace?) async {
        guard !isApplying else { return }
        let next = IpFamily.next(policy)

        // Held across the write AND the read-back as one unit. Clearing it
        // between the two would leave the guard open while `refresh` is
        // suspended on its detached read, and the main actor is free there:
        // a second tap queued behind this one would run, compute
        // `IpFamily.next(policy)` from the PRE-refresh policy this call has
        // already superseded, write that same policy again, and be silently
        // lost -- auto -> force4, tap again -> force4 instead of force6.
        //
        // `defer` rather than an assignment after the read-back so it clears
        // on every exit path, including any early return added later: a stuck
        // flag would wedge the row permanently, which is worse than the lost
        // tap this guards against.
        isApplying = true
        defer { isApplying = false }

        await Task.detached(priority: .userInitiated) {
            if let device {
                device.setControlIpFamilyPolicy(next)
            } else if let networkSpace {
                networkSpace.setControlIpFamilyPolicy(next)
            } else {
                // no device and no space: set this process so the choice is at
                // least in force for the session, even though nothing records it
                SdkSetControlIpFamilyPolicy(next)
            }
        }.value

        await refresh(device: device)
    }
}
