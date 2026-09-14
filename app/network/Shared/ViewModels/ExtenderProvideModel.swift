//
//  ExtenderProvideModel.swift
//  URnetwork
//
//  The provider extender status and the one reading of it the Extender rows
//  draw (EXTENDER.md N2, N3, N7).
//

import Foundation
import SwiftUI
import URnetworkSdk

/**
 * The sdk derives the state of the provider extender role once, for every app
 * (N3). The app keeps the few fields it reads as plain values and turns them
 * into what a row draws in one pure function, so it never re-derives the rule
 * or names a case the sdk did not pick, and so the reading is exercised by the
 * unit tests without a device or a view.
 */

/// One provider extender status, reduced to what the app reads. The Extender
/// row reads `supported`, `state`, `errorCase`, `reason`, the two families and
/// `lastActivationRefused` (N7); the extender statistics section reads
/// `enabled` (O8). Every other field of the sdk status is the state rule's
/// alone.
struct ExtenderProvideStatusModel: Equatable {

    /// The device process carries the role. False hides the row (N1).
    let supported: Bool
    /// One of the sdk's `ExtenderProvideState` values.
    let state: String
    /// One of the sdk's `ExtenderProvideError` values, empty outside the error
    /// state.
    let errorCase: String
    /// The raw error text the case label prefixes. In the active state it is
    /// the other family's last failure, or empty.
    let reason: String
    let activatedV4: Bool
    let activatedV6: Bool
    /// `reason` is the operator's refusal rather than a request that failed.
    let lastActivationRefused: Bool
    /// The role is running. While it is, and the provider statistics show,
    /// the extender statistics show (O4).
    let enabled: Bool

    /// What the app holds until a device reports (N2): the role unsupported,
    /// so the row is hidden, and not running.
    static let unsupported = ExtenderProvideStatusModel(
        supported: false,
        state: SdkExtenderProvideStateOff
    )

    init(
        supported: Bool,
        state: String,
        errorCase: String = "",
        reason: String = "",
        activatedV4: Bool = false,
        activatedV6: Bool = false,
        lastActivationRefused: Bool = false,
        enabled: Bool = false
    ) {
        self.supported = supported
        self.state = state
        self.errorCase = errorCase
        self.reason = reason
        self.activatedV4 = activatedV4
        self.activatedV6 = activatedV6
        self.lastActivationRefused = lastActivationRefused
        self.enabled = enabled
    }

    init(_ status: SdkExtenderProvideStatus) {
        self.init(
            supported: status.supported,
            state: status.state,
            errorCase: status.errorCase,
            reason: status.reason,
            activatedV4: status.activatedV4,
            activatedV6: status.activatedV6,
            lastActivationRefused: status.lastActivationRefused,
            enabled: status.enabled
        )
    }
}

/// The Extender row's status dot (N7): the provide mode indicator's dot
/// without its public ring, with one more color.
enum ExtenderProvideDot: Equatable, CaseIterable {
    /// off and not providing
    case grey
    /// setting up
    case yellow
    /// active
    case green
    /// error
    case red

    /// Grey is the theme's muted text color. Yellow, green and red are the
    /// provide glyph's own asset colors, so the Extender row and the provide
    /// mode row above it never show two yellows.
    func color(mutedColor: Color) -> Color {
        switch self {
        case .grey:
            return mutedColor
        case .yellow:
            return .urYellow
        case .green:
            return .urGreen
        case .red:
            return .urCoral
        }
    }
}

/// What an Extender row draws (N7): whether it shows, its dot, and its one
/// line of state text.
struct ExtenderProvideDisplay: Equatable {

    /// `Supported`. While it is false the row is hidden, never disabled, and
    /// the setting is never written (N1).
    let visible: Bool
    let dot: ExtenderProvideDot
    /// The state line under the title, which is also the row's tooltip and
    /// its accessibility value.
    let text: String

    /// The state line takes the error color in the error state, whatever its
    /// case, and is muted in every other state.
    var isError: Bool {
        dot == .red
    }

    /// The reading of one status. The dot and the text follow `state` and, in
    /// the error state, `errorCase` alone.
    static func of(status: ExtenderProvideStatusModel) -> ExtenderProvideDisplay {
        let dot: ExtenderProvideDot
        let text: String
        switch status.state {
        case SdkExtenderProvideStateOff:
            dot = .grey
            text = String(localized: "Off")
        case SdkExtenderProvideStateNotProviding:
            dot = .grey
            text = String(localized: "Not providing")
        case SdkExtenderProvideStateSettingUp:
            dot = .yellow
            text = String(localized: "Setting up")
        case SdkExtenderProvideStateActive:
            dot = .green
            text = activeText(status)
        case SdkExtenderProvideStateError:
            dot = .red
            text = errorText(status)
        default:
            // a state this app does not know, from a newer device process: no
            // color claim, and the reason as the sdk wrote it
            dot = .grey
            text = status.reason
        }
        return ExtenderProvideDisplay(visible: status.supported, dot: dot, text: text)
    }

    /// The row's local repaint when the switch is toggled, before the listener
    /// answers (N7): off is grey `Off`; on is yellow `Setting up` while the
    /// device is providing and grey `Not providing` while it is not. The next
    /// status replaces it.
    static func guess(on: Bool, providing: Bool) -> ExtenderProvideDisplay {
        let state: String
        if !on {
            state = SdkExtenderProvideStateOff
        } else if providing {
            state = SdkExtenderProvideStateSettingUp
        } else {
            state = SdkExtenderProvideStateNotProviding
        }
        return of(status: ExtenderProvideStatusModel(supported: true, state: state))
    }

    /// `Active · <families>`, followed on the same line, when the other
    /// family's last attempt failed, by that family's refusal or failure.
    /// Both arrive as plain text, so `lastActivationRefused` says which.
    private static func activeText(_ status: ExtenderProvideStatusModel) -> String {
        let families: String
        if status.activatedV4 && status.activatedV6 {
            families = String(localized: "IPv4 and IPv6")
        } else if status.activatedV6 {
            families = String(localized: "IPv6")
        } else {
            families = String(localized: "IPv4")
        }
        let active = String(format: String(localized: "Active · %@"), families)
        guard !status.reason.isEmpty else {
            return active
        }
        return active + " · " + activationText(
            refused: status.lastActivationRefused,
            reason: status.reason
        )
    }

    /// The error state's text, by `errorCase` alone. A case this app does not
    /// know renders the reason bare.
    private static func errorText(_ status: ExtenderProvideStatusModel) -> String {
        switch status.errorCase {
        case SdkExtenderProvideErrorRevoked:
            return String(localized: "Revoked by the operator")
        case SdkExtenderProvideErrorStart:
            return String(format: String(localized: "Could not start: %@"), status.reason)
        case SdkExtenderProvideErrorListen:
            return String(format: String(localized: "Could not listen: %@"), status.reason)
        case SdkExtenderProvideErrorActivationRefused:
            return activationText(refused: true, reason: status.reason)
        case SdkExtenderProvideErrorActivationFailed:
            return activationText(refused: false, reason: status.reason)
        default:
            return status.reason
        }
    }

    private static func activationText(refused: Bool, reason: String) -> String {
        if refused {
            return String(format: String(localized: "Activation refused: %@"), reason)
        }
        return String(format: String(localized: "Activation failed: %@"), reason)
    }
}
