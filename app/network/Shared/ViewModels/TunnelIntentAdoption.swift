//
//  TunnelIntentAdoption.swift
//  URnetwork
//
//  Folds a connect/disconnect decision made outside the app (the Control
//  Center toggle, the widget, or a stop from Settings) into the app's own
//  connect state, so the app's reconciler does not undo it on the next
//  foreground. See network/Shared/Widgets/TunnelIntentStore.swift for the
//  shared record.
//
//  The app's connect state is the SDK local state's connect location: a
//  saved location means "connect", nil means "disconnected". Adopting a
//  shared disconnect clears it; adopting a shared connect fills it with the
//  running tunnel's location when reachable, else the last selected
//  location, else best available (the same rule the tunnel extension applies
//  when it starts without a location).
//

import Foundation
import URnetworkSdk

enum TunnelIntentAdoption {

    /// When the app last applied (or made) a decision, so an older shared
    /// intent is never re-applied. App-private.
    static let appliedAtKey = "network.ur.tunnel-intent.applied-at"

    static var appliedAt: Date? {
        UserDefaults.standard.object(forKey: appliedAtKey) as? Date
    }

    static func markApplied(_ date: Date) {
        UserDefaults.standard.set(date, forKey: appliedAtKey)
    }

    /// Records an in-app connect or disconnect for the other processes and
    /// marks it applied.
    static func recordAppIntent(connect: Bool) {
        let intent = TunnelIntentStore.record(connect: connect, source: TunnelIntentStore.sourceApp)
        markApplied(intent.changedAt)
    }

    /// The newest shared intent the app has not applied yet, if any.
    static func pendingIntent() -> TunnelIntent? {
        guard let intent = TunnelIntentStore.load(),
              intent.source != TunnelIntentStore.sourceApp,
              TunnelIntentStore.supersedes(intent, localChangedAt: appliedAt) else {
            return nil
        }
        return intent
    }

    /// Applies a pending shared intent to the local state and, when present,
    /// the device. Returns the intent that was applied.
    @discardableResult
    static func adoptPending(localState: SdkLocalState?, device: SdkDeviceRemote?) -> TunnelIntent? {
        guard let intent = pendingIntent() else {
            return nil
        }
        if intent.connect {
            let current = device?.getConnectLocation() ?? localState?.getConnectLocation()
            let location = current ?? localState?.getDefaultLocation() ?? bestAvailableLocation()
            if localState?.getConnectLocation() == nil {
                try? localState?.setConnectLocation(location)
            }
            if current == nil {
                device?.setConnectLocation(location)
            }
        } else {
            try? localState?.setConnectLocation(nil)
            if device?.getConnectLocation() != nil {
                device?.setConnectLocation(nil)
            }
        }
        markApplied(intent.changedAt)
        print("[TunnelIntentAdoption] adopted \(intent.connect ? "connect" : "disconnect") from \(intent.source)")
        return intent
    }

    static func bestAvailableLocation() -> SdkConnectLocation {
        let id = SdkConnectLocationId()
        id.bestAvailable = true
        let location = SdkConnectLocation()
        location.connectLocationId = id
        return location
    }
}
