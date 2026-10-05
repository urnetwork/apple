//
//  ControlDohSettingsForm.swift
//  URnetwork
//

import Foundation

/**
 * The bootstrap DNS-over-HTTPS servers of a network space (P216): servers the
 * space resolves its own names (api, connect, extender) through ahead of the
 * default DoH servers, for networks that block those. Account > Extenders and
 * the login screen's network sheet edit them.
 *
 * Only plain values live here, so the field's rules are tested without a
 * device or the sdk: how the multiline field reads as a list and shows one,
 * and the message of an sdk error id. Checking a url, the presets and storing
 * are the sdk's (`ValidateControlDohUrl`, `RegionalControlDohUrls`,
 * `NetworkSpace.SetControlDohUrls`), one implementation for every app;
 * `ControlDohSettingsStore` adapts between the two.
 */

// MARK: - the field

/// The country of the "Use China resolvers" preset (`RegionalControlDohUrls`).
enum ControlDohPreset {
    static let china = "cn"
}

/// The servers of the multiline field, in the order typed. A line ends at a
/// \n or a \r, so text pasted with Windows line endings reads the same, and
/// surrounding whitespace and blank lines are not servers. A comma does not
/// separate servers, since a url may carry one. The sdk drops repeats and
/// normalizes each url.
func controlDohUrls(_ text: String) -> [String] {
    text.components(separatedBy: CharacterSet(charactersIn: "\n\r"))
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
}

/// The field's text for a list of servers: one url per line. No servers is an
/// empty field, which means the default servers alone.
func controlDohText(_ urls: [String]) -> String {
    urls.joined(separator: "\n")
}

// MARK: - errors

/// The sdk's error ids (`SdkControlDohError*`). Each id is also the
/// localization key id of its message in the localizations store.
enum ControlDohErrorId {
    static let urlInvalid = "control_doh_error_url_invalid"
    static let httpsRequired = "control_doh_error_https_required"
    static let ipRequired = "control_doh_error_ip_required"
    static let tooMany = "control_doh_error_too_many"

    static let all: [String] = [
        urlInvalid,
        httpsRequired,
        ipRequired,
        tooMany,
    ]
}

/// The message of an sdk error id. An id this build does not know reads as an
/// invalid url, the sdk's catch-all.
func controlDohErrorMessage(_ errorId: String) -> LocalizedStringResource {
    switch errorId {
    case ControlDohErrorId.httpsRequired:
        return "The URL must start with https://."
    case ControlDohErrorId.ipRequired:
        return "Use an IP address, not a host name, such as https://223.5.5.5/dns-query."
    case ControlDohErrorId.tooMany:
        return "Too many servers. Remove some and save again."
    default:
        // control_doh_error_url_invalid, and any id this build does not know
        return "Enter a full URL, such as https://223.5.5.5/dns-query."
    }
}
