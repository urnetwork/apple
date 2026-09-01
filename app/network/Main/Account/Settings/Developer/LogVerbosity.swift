//
//  LogVerbosity.swift
//  URnetwork
//
//  What each glog verbosity level buys, and what it costs.
//
//  The `connect` package gates most of what it has to say behind V(1) and
//  V(2) -- contract accounting, transport internals, window diagnostics -- and
//  every process starts at 0, where none of it is written. A bundle exported
//  from a live session therefore contains the rpc chatter and nothing about
//  the contracts or the transport, which is the part a connection report needs.
//  This is the vocabulary for the control that raises it.
//
//  Pure so it can be tested without a device: the level-to-label mapping and
//  the clamp are the whole of the logic, and both are load-bearing -- one
//  names what the user is turning on, the other keeps an out-of-range value
//  from indexing past the labels.
//

import Foundation

enum LogVerbosity {

    /// The range the SDK honors. `connect` only ever asks for V(1) and V(2),
    /// so anything above 2 is volume with nothing to show for it, and the SDK
    /// clamps to this range on its own -- mirrored here so the control never
    /// offers a level that would come back changed.
    static let minimum = 0
    static let maximum = 2

    static var range: ClosedRange<Int> { minimum...maximum }

    static func clamp(_ level: Int) -> Int {
        min(max(level, minimum), maximum)
    }

    /**
     * Shown in place of a level when there is no device to read one from.
     *
     * NOT the same claim as "Default". Level 0 says the process that writes
     * the logs reports it is at 0; this says nobody has been asked yet, so
     * the level is unknown. The whole reason the row reads back from the
     * device is that the contract and transport logging happens in the packet
     * tunnel extension, not in this process -- so with no device there is
     * nothing to report and a number here would be a guess.
     */
    static let unavailableLabel = "Unavailable"

    /// Why the row is inert, in the Diagnostics section's voice: what is
    /// missing, and what to do about it -- the same shape as the
    /// unavailable-source lines beneath it. Matches Android's
    /// `dev_log_verbosity_unavailable_detail`.
    static let unavailableDetail =
        "There is no device to read the log level from yet. Sign in first."

    /**
     * The user-facing name of a level, or of not having one.
     *
     * `nil` means there is no device to ask, and is deliberately distinct
     * from 0 -- see `unavailableLabel`.
     *
     * These are also the SDK's constant names: `SdkLogVerbosityVerbose` is 1
     * and `SdkLogVerbosityTrace` is 2. The SDK follows these labels rather
     * than the other way round -- the word a bug report quotes is the one the
     * user read here, so the number and the word agree on both sides.
     */
    static func name(_ level: Int?) -> String {
        guard let level else { return unavailableLabel }
        switch clamp(level) {
        case minimum: return "Default"
        case 1: return "Verbose"
        default: return "Trace"
        }
    }

    /**
     * What that level actually buys, and what it costs -- named concretely
     * rather than as "more logging", so the choice can be made before the
     * reproduction rather than discovered in the bundle afterwards.
     */
    static func detail(_ level: Int?) -> String {
        guard let level else { return unavailableDetail }
        switch clamp(level) {
        case minimum:
            return "Connection errors and contract pings."
        case 1:
            return "Contract accounting and per-packet block decisions."
                + " Includes destination IP addresses."
        default:
            return "Transport and window internals. Very large logs."
        }
    }

    /// Number and name together: the number is what the SDK reports and what
    /// a support thread can compare, the name is what the row means. With no
    /// device there is no number the device gave, so the label is the
    /// unavailable one alone rather than a level nobody reported.
    static func valueLabel(_ level: Int?) -> String {
        guard let level else { return unavailableLabel }
        return "\(level) · \(name(level))"
    }

    /**
     * Whether logs written at this level carry the destinations of real
     * traffic. True from V(1) up: that is where the per-packet block
     * decisions and the contract accounting start naming addresses.
     *
     * Written against the level rather than a stored flag so a level restored
     * from a previous run, or one an embedder set some other way, warns the
     * same as one just chosen here.
     *
     * `nil` -- no device, so nothing was read back -- is not a warning. The
     * warning is a claim about what IS being written, and with no device that
     * is unknown in both directions; asserting it would be as much of a guess
     * as reporting level 0.
     */
    static func revealsDestinations(_ level: Int?) -> Bool {
        guard let level else { return false }
        return minimum < level
    }

    /// Shown for as long as the level is raised, not once when it is changed:
    /// the user raises it, reproduces for an hour, and exports -- and by then
    /// a toast is long gone.
    static let destinationWarning =
        "Logs now record the destination addresses and ports of your real traffic."
        + " Send the redacted export, not the raw one."
}
