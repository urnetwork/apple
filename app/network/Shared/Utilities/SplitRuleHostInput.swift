//
//  SplitRuleHostInput.swift
//  URnetwork
//
//  What a hand-typed split rule host is allowed to be.
//
//  The invariant this file exists to hold: NEVER be more permissive than the
//  Go matcher. That matcher has no error channel -- anything it cannot parse
//  as a wildcard, a prefix or an address is filed as an exact host name
//  (connect/ip_block_action.go:385-406), so a typo produces a rule that is
//  created, persisted, mirrored, seeded, counted in the "N split rules" card
//  and matched never. There is nowhere downstream to report that. Rejecting a
//  value the matcher would have accepted only costs the user a rephrase;
//  accepting one it will never match costs them a rule they believe is
//  working. When in doubt, reject.
//
//  Kept free of SwiftUI and of the SDK so it can be tested directly. The
//  durable fix is one normalizer in Go called by the matcher itself and bound
//  through gomobile, the way host-name collapsing already works; until that
//  lands this is the second implementation of a grammar that has one owner.
//

import Foundation
import Network

enum SplitRuleHostError: Equatable {
    case notAscii
    case badName
    case badWildcard
    case badRange
    case duplicate
    /// Another value in the same rule already matches everything this would.
    case covered(by: String)
}

struct SplitRuleHostValidation: Equatable {
    /// The value as it will be stored, lowercased and trimmed, with an IP
    /// range masked to its network address the way the matcher keys it.
    let normalized: String?
    let error: SplitRuleHostError?
    /// Set when the stored value differs from what was typed, so the change
    /// is something the user agreed to rather than something Go did quietly.
    let note: String?

    var isAccepted: Bool { normalized != nil && error == nil }
}

enum SplitRuleHostInput {

    /// Longest legal DNS name, and longest legal label.
    private static let maxNameLength = 253
    private static let maxLabelLength = 63

    /// Validates one typed value against the values already in the rule.
    static func validate(_ raw: String, existing: [String] = []) -> SplitRuleHostValidation {
        let host = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if host.isEmpty {
            return SplitRuleHostValidation(normalized: nil, error: nil, note: nil)
        }
        // the matcher lowercases and compares bytes; a resolved name arrives
        // as punycode, so a unicode name here could only ever be dead
        guard host.allSatisfy({ $0.isASCII }) else {
            return rejected(.notAscii)
        }

        let normalized: String
        var note: String? = nil

        if let base = host.dropPrefixIfPresent("**.") ?? host.dropPrefixIfPresent("*.") {
            guard isValidName(base) else {
                return rejected(.badWildcard)
            }
            normalized = host
        } else if host.contains("/") {
            guard let masked = maskedPrefix(host) else {
                return rejected(.badRange)
            }
            normalized = masked
            if masked != host {
                note = masked
            }
        } else if let address = normalizedAddress(host) {
            normalized = address
            if address != host {
                note = address
            }
        } else {
            guard isValidName(host) else {
                return rejected(.badName)
            }
            normalized = host
        }

        if existing.contains(normalized) {
            return rejected(.duplicate)
        }
        if let cover = existing.first(where: { covers($0, normalized) }) {
            return SplitRuleHostValidation(normalized: nil, error: .covered(by: cover), note: nil)
        }
        return SplitRuleHostValidation(normalized: normalized, error: nil, note: note)
    }

    private static func rejected(_ error: SplitRuleHostError) -> SplitRuleHostValidation {
        SplitRuleHostValidation(normalized: nil, error: error, note: nil)
    }

    /// A dotted name of at least two labels. Single-label names parse as
    /// exact hosts in Go but can never match a resolved destination, so they
    /// are refused here rather than stored as a rule that does nothing.
    static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= maxNameLength, !name.hasSuffix(".") else {
            return false
        }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        guard 2 <= labels.count else {
            return false
        }
        return labels.allSatisfy { label in
            guard !label.isEmpty, label.count <= maxLabelLength else {
                return false
            }
            guard !label.hasPrefix("-"), !label.hasSuffix("-") else {
                return false
            }
            return label.allSatisfy { $0.isLowercaseASCIILetter || $0.isASCIIDigit || $0 == "-" }
        }
    }

    /// An address, in the form the matcher stores it: an ipv4-mapped ipv6
    /// address is unmapped there, so it is unmapped here too.
    static func normalizedAddress(_ value: String) -> String? {
        if let v4 = IPv4Address(value) {
            return v4.debugDescription
        }
        guard let v6 = IPv6Address(value) else {
            return nil
        }
        // ::ffff:1.2.3.4 -> 1.2.3.4, matching netip's Unmap()
        let bytes = [UInt8](v6.rawValue)
        if bytes.count == 16,
           bytes[0..<10].allSatisfy({ $0 == 0 }),
           bytes[10] == 0xff, bytes[11] == 0xff,
           let mapped = IPv4Address(Data(bytes[12..<16]), nil) {
            return mapped.debugDescription
        }
        return v6.debugDescription
    }

    /// A CIDR range, masked to its network address. Go masks it before
    /// matching, so `192.168.1.42/24` becomes `192.168.1.0/24` there; doing
    /// it here means the chip shows what is actually in force.
    static func maskedPrefix(_ value: String) -> String? {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let bits = Int(parts[1]),
              !parts[1].isEmpty else {
            return nil
        }
        let address = String(parts[0])
        if let v4 = IPv4Address(address) {
            guard 0...32 ~= bits, let masked = mask(v4.rawValue, bits: bits, of: 4),
                  let result = IPv4Address(masked, nil) else {
                return nil
            }
            return "\(result.debugDescription)/\(bits)"
        }
        if let v6 = IPv6Address(address) {
            guard 0...128 ~= bits, let masked = mask(v6.rawValue, bits: bits, of: 16),
                  let result = IPv6Address(masked, nil) else {
                return nil
            }
            return "\(result.debugDescription)/\(bits)"
        }
        return nil
    }

    private static func mask(_ raw: Data, bits: Int, of byteCount: Int) -> Data? {
        var bytes = [UInt8](raw)
        guard bytes.count == byteCount else {
            return nil
        }
        for index in 0..<byteCount {
            let bitsBefore = index * 8
            if bits <= bitsBefore {
                bytes[index] = 0
            } else if bits < bitsBefore + 8 {
                // keep is 1...7 here: this byte is the one the prefix ends
                // inside. The mask is built in UInt8 throughout -- `0xff` is
                // an Int literal, so shifting it left and converting back
                // traps for every prefix length that is not a whole number
                // of bytes, which is most of them.
                let dropped = UInt8(8 - (bits - bitsBefore))
                bytes[index] &= ~((UInt8(1) << dropped) &- 1)
            }
        }
        return Data(bytes)
    }

    /// True when `wildcard` already matches everything `candidate` would.
    /// Only the wildcard forms can cover another value; two exact values
    /// never cover each other. Adding both is not harmful, but the rule row
    /// collapses them into one chip, so the user would see one value where
    /// they deliberately typed two.
    static func covers(_ wildcard: String, _ candidate: String) -> Bool {
        if let base = wildcard.dropPrefixIfPresent("**.") {
            return candidate == base || candidate.hasSuffix("." + base)
        }
        if let base = wildcard.dropPrefixIfPresent("*.") {
            return candidate.hasSuffix("." + base)
        }
        return false
    }

    /// The reason a value was refused, for the line under the field.
    static func message(for error: SplitRuleHostError) -> String {
        switch error {
        case .notAscii:
            return String(localized: "Use the ASCII form of the name.")
        case .badName:
            return String(localized: "Enter a host name like example.com.")
        case .badWildcard:
            return String(localized: "A wildcard needs a name after it, like *.example.com.")
        case .badRange:
            return String(localized: "Enter an IP range like 10.0.0.0/8.")
        case .duplicate:
            return String(localized: "Already in this rule.")
        case .covered(let by):
            return String(format: String(localized: "Already covered by %@ in this rule."), by)
        }
    }
}

private extension String {
    func dropPrefixIfPresent(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}

private extension Character {
    var isLowercaseASCIILetter: Bool { "a"..."z" ~= self }
    var isASCIIDigit: Bool { "0"..."9" ~= self }
}
