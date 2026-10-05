//
//  SplitTunnelProxyPlan.swift
//  URnetwork
//
//  The pure half of driving the macOS split tunnel: given what the app
//  wants, whether the user wants the VPN connected, the system extension's
//  activation state and the transparent proxy configuration the system
//  holds, the one next step that moves the system toward it. The controller
//  (SplitTunnelProxyController.swift, macOS only) performs the step, observes
//  again, and asks for the next one until there is none, so every path --
//  launch, an edit, connect, disconnect, an approval arriving late -- goes
//  through the same convergent loop.
//
//  The proxy runs only while the user wants the VPN connected: with the VPN
//  off every flow already goes direct, and relaying the excluded apps
//  through the extension would only cost them. It is a no-op the other way
//  too -- a proxy that failed to start leaves the excluded apps in the
//  tunnel, never the reverse.
//
//  No NetworkExtension import, so it compiles into every build and the unit
//  tests drive it on the iOS simulator.
//

import Foundation

/// The transparent proxy configuration as the system holds it.
struct SplitTunnelProxyObserved: Equatable {
    /// nil when no split tunnel configuration is installed, or when the
    /// installed one carries no list this build can read
    var configuration: SplitTunnelProxyConfiguration?
    var isInstalled: Bool
    var isEnabled: Bool
    /// connecting, connected or reasserting
    var isRunning: Bool

    static let absent = SplitTunnelProxyObserved(
        configuration: nil,
        isInstalled: false,
        isEnabled: false,
        isRunning: false
    )
}

struct SplitTunnelProxyInputs: Equatable {
    /// The excluded apps from a rule list this process can vouch for as the
    /// whole list (see BlockActionsStore); nil until there is one, and then
    /// the installed configuration's own list stands.
    var wantedApps: [String]?
    var connectEnabled: Bool
    var extensionState: SystemExtensionActivationState
    /// nil until the configurations have been loaded
    var observed: SplitTunnelProxyObserved?
}

enum SplitTunnelProxyStep: Equatable {
    case none
    case load
    case activateExtension
    /// save (create or replace) the configuration, enabled; when the proxy
    /// is running the controller also hands it the new list
    case save(SplitTunnelProxyConfiguration)
    case remove
    case start
    case stop
}

enum SplitTunnelProxyStatus: Equatable {
    /// no app is excluded
    case off
    /// installing the extension or the configuration
    case pending
    /// the one-time System Settings approval of the extension is pending
    case needsApproval
    /// the extension or the configuration could not be installed or started
    case failed
    /// configured; the excluded apps bypass the VPN while it is connected
    case ready
    /// the proxy is running
    case active
}

enum SplitTunnelProxyPlan {

    static func nextStep(_ inputs: SplitTunnelProxyInputs) -> SplitTunnelProxyStep {
        guard let observed = inputs.observed else {
            return .load
        }
        if let wanted = inputs.wantedApps, SplitTunnelProxyConfiguration(excludedApps: wanted).isEmpty {
            return observed.isInstalled ? .remove : .none
        }
        // with no list to go by, an installed configuration is still in use:
        // it keeps its own list and follows the VPN
        guard inputs.wantedApps != nil || observed.isInstalled else {
            return .none
        }
        switch inputs.extensionState {
        case .idle:
            // also how an extension embedded in an updated app replaces the
            // installed one; an already active extension completes at once
            return .activateExtension
        case .requesting, .needsApproval, .notInApplications, .failed:
            // the activation result re-runs the plan; a failure waits for the
            // user (Retry)
            return .none
        case .activated:
            break
        }
        if let wanted = inputs.wantedApps {
            let configuration = SplitTunnelProxyConfiguration(excludedApps: wanted)
            if !observed.isInstalled || observed.configuration != configuration || !observed.isEnabled {
                return .save(configuration)
            }
        }
        if inputs.connectEnabled && observed.isEnabled && !observed.isRunning {
            return .start
        }
        if !inputs.connectEnabled && observed.isRunning {
            return .stop
        }
        return .none
    }

    /// What the Apps section says. `failed` is the controller's latch: the
    /// last step failed and the inputs have not changed since.
    static func status(_ inputs: SplitTunnelProxyInputs, failed: Bool) -> SplitTunnelProxyStatus {
        let wantsApps: Bool
        if let wanted = inputs.wantedApps {
            wantsApps = !SplitTunnelProxyConfiguration(excludedApps: wanted).isEmpty
        } else {
            wantsApps = inputs.observed?.isInstalled ?? false
        }
        guard wantsApps else {
            return .off
        }
        switch inputs.extensionState {
        case .needsApproval:
            return .needsApproval
        case .notInApplications, .failed:
            return .failed
        case .idle, .requesting, .activated:
            break
        }
        if failed {
            return .failed
        }
        guard inputs.extensionState.isActivated, let observed = inputs.observed else {
            return .pending
        }
        if observed.isRunning {
            return .active
        }
        return nextStep(inputs) == .none ? .ready : .pending
    }
}
