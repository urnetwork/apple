//
//  SystemExtensionActivation.swift
//  URnetwork
//
//  The pure half of activating the packet tunnel SYSTEM extension in the
//  direct-download macOS build (`DIRECT_DOWNLOAD`): where the app may be
//  installed for activation to work, how each OSSystemExtensionRequest
//  delegate callback moves the state, and what the app says to the user in
//  each state. No SystemExtensions import, so it compiles into every build
//  and the unit tests drive it on the iOS simulator; the framework-facing
//  delegate lives in SystemExtensionActivator.swift.
//

import Foundation

/// Where the running app bundle lives. macOS only activates system
/// extensions embedded in an app under /Applications; an app run straight
/// from the mounted DMG (or from ~/Downloads) is rejected with
/// `unsupportedParentBundleLocation`, so the app checks first and explains
/// instead of submitting a request it knows will fail.
enum SystemExtensionInstallLocation: Equatable {
    case applications
    case diskImage
    case elsewhere

    static let applicationsDirectory = "/Applications"
    static let volumesDirectory = "/Volumes"

    static func classify(bundlePath: String) -> SystemExtensionInstallLocation {
        let path = URL(fileURLWithPath: bundlePath).standardizedFileURL.path
        if path.hasPrefix(applicationsDirectory + "/") {
            return .applications
        }
        if path.hasPrefix(volumesDirectory + "/") {
            return .diskImage
        }
        return .elsewhere
    }

    var canActivate: Bool { self == .applications }

    /// Where "Move to Applications" puts the bundle: the same bundle name
    /// directly under /Applications.
    static func moveDestination(bundlePath: String) -> String {
        let name = URL(fileURLWithPath: bundlePath).lastPathComponent
        return applicationsDirectory + "/" + name
    }
}

/// `OSSystemExtensionError.Code`, mirrored so the reducer and its tests do
/// not need the framework. SystemExtensionActivator maps the real codes
/// with an exhaustive switch.
enum SystemExtensionActivationFailure: Equatable {
    case unsupportedParentBundleLocation
    case missingEntitlement
    case extensionNotFound
    case codeSignatureInvalid
    case validationFailed
    case forbiddenBySystemPolicy
    case requestCanceled
    case requestSuperseded
    case authorizationRequired
    case other(code: Int, description: String)

    /// Failures that mean the bundle, not the user, is the problem.
    var meansNotInApplications: Bool { self == .unsupportedParentBundleLocation }
}

enum SystemExtensionActivationState: Equatable {
    case idle
    /// The app is not under /Applications; nothing was submitted.
    case notInApplications(SystemExtensionInstallLocation)
    case requesting
    /// The one-time System Settings approval is pending.
    case needsApproval
    /// The extension is installed (or a replacement of an older version
    /// will be, after the next reboot -- the system says which).
    case activated(willCompleteAfterReboot: Bool)
    case failed(SystemExtensionActivationFailure)

    var isActivated: Bool {
        if case .activated = self { return true }
        return false
    }

    /// The states the app should explain in a prompt.
    var needsUserAction: Bool {
        switch self {
        case .notInApplications, .needsApproval:
            return true
        case .failed(let failure):
            return failure.meansNotInApplications
        case .idle, .requesting, .activated:
            return false
        }
    }

    var needsMoveToApplications: Bool {
        switch self {
        case .notInApplications:
            return true
        case .failed(let failure):
            return failure.meansNotInApplications
        default:
            return false
        }
    }
}

enum SystemExtensionActivationEvent: Equatable {
    /// The app asked for activation from `location`.
    case activationRequested(SystemExtensionInstallLocation)
    /// `request(_:actionForReplacingExtension:withExtension:)` fired; the
    /// request stays in flight.
    case replacing(existingVersion: String, candidateVersion: String)
    /// `requestNeedsUserApproval(_:)`.
    case needsUserApproval
    /// `request(_:didFinishWithResult:)`.
    case finished(willCompleteAfterReboot: Bool)
    /// `request(_:didFailWithError:)`.
    case failed(SystemExtensionActivationFailure)
}

/// What the delegate answers when an older (or equal) copy of the extension
/// is already installed.
enum SystemExtensionReplacementDecision: Equatable {
    case replace
    case cancel
}

enum SystemExtensionActivation {

    /// Whether a new request should be submitted from `state`. A request
    /// already in flight (or waiting on the user) is not duplicated; every
    /// other state, including `activated`, re-submits -- activation of an
    /// already-active extension completes immediately, and re-submitting is
    /// what repairs an extension the user removed in System Settings.
    static func shouldSubmit(from state: SystemExtensionActivationState) -> Bool {
        switch state {
        case .requesting, .needsApproval:
            return false
        case .idle, .notInApplications, .activated, .failed:
            return true
        }
    }

    static func reduce(
        _ state: SystemExtensionActivationState,
        _ event: SystemExtensionActivationEvent
    ) -> SystemExtensionActivationState {
        switch event {
        case .activationRequested(let location):
            guard location.canActivate else { return .notInApplications(location) }
            // a re-check of an active extension stays "activated" rather than
            // flashing a spinner; the result events below still apply
            if state.isActivated { return state }
            return .requesting
        case .replacing:
            return state.isActivated ? state : .requesting
        case .needsUserApproval:
            return .needsApproval
        case .finished(let willCompleteAfterReboot):
            return .activated(willCompleteAfterReboot: willCompleteAfterReboot)
        case .failed(let failure):
            return .failed(failure)
        }
    }

    /// Always replace: the candidate is the extension this very app bundle
    /// ships, so an older installed copy must go, and re-installing an equal
    /// version is how a damaged one gets repaired. Cancelling would leave a
    /// tunnel that does not match the app talking to it.
    static func replacementDecision(
        existingVersion: String,
        candidateVersion: String
    ) -> SystemExtensionReplacementDecision {
        .replace
    }
}

/// The user-facing copy for the prompt states.
enum SystemExtensionActivationCopy {

    static let extensionDisplayName = "URnetwork VPN"

    static func title(for state: SystemExtensionActivationState, appName: String) -> String? {
        switch state {
        case .needsApproval:
            return "Allow the \(appName) network extension"
        case .notInApplications, .failed(.unsupportedParentBundleLocation):
            return "Move \(appName) to Applications"
        case .failed:
            return "The \(appName) network extension could not be installed"
        case .idle, .requesting, .activated:
            return nil
        }
    }

    static func message(for state: SystemExtensionActivationState, appName: String) -> String? {
        switch state {
        case .needsApproval:
            return "macOS asks once before a VPN extension can run. Open System Settings, "
                + "go to General > Login Items & Extensions > Network Extensions, and allow "
                + "\"\(extensionDisplayName)\". Then come back and connect."
        case .notInApplications(.diskImage):
            return "\(appName) is running from the disk image. macOS only installs VPN "
                + "extensions from apps in the Applications folder. Move \(appName) to "
                + "Applications and open it from there."
        case .notInApplications, .failed(.unsupportedParentBundleLocation):
            return "macOS only installs VPN extensions from apps in the Applications folder. "
                + "Move \(appName) to Applications and open it from there."
        case .failed(.forbiddenBySystemPolicy):
            return "A system policy on this Mac blocks the network extension. "
                + "Ask whoever manages this Mac to allow \"\(extensionDisplayName)\"."
        case .failed(.other(_, let description)):
            return description
        case .failed(let failure):
            return "Installing the network extension failed (\(failure)). Reinstalling \(appName) usually fixes this."
        case .idle, .requesting, .activated:
            return nil
        }
    }

    static func primaryAction(for state: SystemExtensionActivationState) -> String? {
        switch state {
        case .needsApproval:
            return "Open System Settings"
        case .notInApplications, .failed(.unsupportedParentBundleLocation):
            return "Move to Applications"
        default:
            return nil
        }
    }
}
