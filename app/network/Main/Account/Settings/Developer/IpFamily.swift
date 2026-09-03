//
//  IpFamily.swift
//  URnetwork
//
//  Which address family the control plane dials over, and what each choice
//  costs.
//
//  The service publishes both an A and an AAAA record for its api and its
//  control websocket, and the AAAA is in a tunnel-brokered range some ISPs
//  route badly. Such a path completes the tcp handshake -- small packets pass
//  -- and then drops the larger tls handshake, so the platform's own Happy
//  Eyeballs race picks it, declares it the winner, and stalls. The sdk demotes
//  a family that fails that way on its own; this is the override for when it
//  does not, and the way to prove the diagnosis on a device that reproduces it.
//
//  Pure so it can be tested without a device: the policy-to-label mapping, the
//  clamp and the cycle order are the whole of the logic.
//

import Foundation
import URnetworkSdk

enum IpFamily {

    /// Mirrors the sdk's constants. Read the numbers from the sdk rather than
    /// redeclaring them, so a rename on the Go side is a compile error here
    /// rather than a silently wrong row.
    static let auto = Int(SdkIpFamilyPolicyAuto)
    static let force4 = Int(SdkIpFamilyPolicyForce4)
    static let force6 = Int(SdkIpFamilyPolicyForce6)

    /// Anything the sdk would not recognise is Automatic, matching what the
    /// sdk itself does with an out-of-range value.
    static func clamp(_ policy: Int) -> Int {
        switch policy {
        case force4: return force4
        case force6: return force6
        default: return auto
        }
    }

    /// Tap order. Automatic first so the row returns to the safe default
    /// without the user having to know which force is which.
    static func next(_ policy: Int) -> Int {
        switch clamp(policy) {
        case auto: return force4
        case force4: return force6
        default: return auto
        }
    }

    static func name(_ policy: Int) -> String {
        switch clamp(policy) {
        case force4: return "Force IPv4"
        case force6: return "Force IPv6"
        default: return "Automatic"
        }
    }

    /**
     * What this policy means right now, including anything the sdk has
     * learned.
     *
     * `status` is the sdk's demotion description and is empty when nothing is
     * demoted. It is reported only under Automatic: a force does not consult
     * the ledger, so naming a demotion beside one would describe state that is
     * not in effect.
     */
    static func detail(_ policy: Int, status: String) -> String {
        switch clamp(policy) {
        case force4:
            return "Control-plane connections use IPv4 only."
                + " Turn this off on an IPv6-only network."
        case force6:
            return "Control-plane connections use IPv6 only."
                + " Turn this off if the app cannot reach the server."
        default:
            if !status.isEmpty {
                return "Automatic. \(status)."
            }
            return "Uses whichever family connects first,"
                + " and routes around one that fails after connecting."
        }
    }

    /// Name alone. There is no number worth showing here -- unlike the log
    /// level, the policy's integer means nothing to a support thread that the
    /// word does not already say.
    static func valueLabel(_ policy: Int) -> String {
        name(policy)
    }
}
