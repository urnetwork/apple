//
//  SplitRuleHostInputTests.swift
//  networkTests
//
//  The grammar behind the hand-typed split rule host.
//
//  These matter more than most input validation because the failure is
//  silent. The Go matcher files anything it cannot parse as an exact host
//  name and there is no error channel anywhere on the write path, so an
//  accepted-but-wrong value becomes a rule that is created, persisted,
//  mirrored, counted on the connect card and matched never. Every case below
//  that asserts a REJECTION is guarding that, not tidiness.
//

import Testing
import Foundation
@testable import URnetwork

struct SplitRuleHostInputTests {

    @Test func plainNamesAreAccepted() {
        #expect(SplitRuleHostInput.validate("example.com").normalized == "example.com")
        #expect(SplitRuleHostInput.validate("a1366.dscapi6.akamai.net").normalized == "a1366.dscapi6.akamai.net")
        #expect(SplitRuleHostInput.validate("my-host.example.co.uk").normalized == "my-host.example.co.uk")
    }

    @Test func inputIsTrimmedAndLowercased() {
        #expect(SplitRuleHostInput.validate("  Example.COM  ").normalized == "example.com")
    }

    /// The matcher lowercases and compares bytes, and a resolved name arrives
    /// as punycode, so a unicode name could only ever be a dead rule.
    @Test func unicodeNamesAreRefused() {
        #expect(SplitRuleHostInput.validate("münchen.de").error == .notAscii)
    }

    /// Parses in Go as an exact host, but nothing resolves to it, so it would
    /// be a rule that does nothing.
    @Test func singleLabelNamesAreRefused() {
        #expect(SplitRuleHostInput.validate("localhost").error == .badName)
        #expect(SplitRuleHostInput.validate("router").error == .badName)
    }

    @Test func malformedNamesAreRefused() {
        #expect(SplitRuleHostInput.validate("example..com").error == .badName)
        #expect(SplitRuleHostInput.validate("-example.com").error == .badName)
        #expect(SplitRuleHostInput.validate("example-.com").error == .badName)
        #expect(SplitRuleHostInput.validate("example.com.").error == .badName)
        #expect(SplitRuleHostInput.validate("exa mple.com").error == .badName)
    }

    @Test func wildcardsAreAccepted() {
        #expect(SplitRuleHostInput.validate("*.example.com").normalized == "*.example.com")
        #expect(SplitRuleHostInput.validate("**.example.com").normalized == "**.example.com")
    }

    @Test func wildcardsNeedAName() {
        #expect(SplitRuleHostInput.validate("*.").error == .badWildcard)
        #expect(SplitRuleHostInput.validate("**.").error == .badWildcard)
        #expect(SplitRuleHostInput.validate("*.com").error == .badWildcard)
    }

    @Test func addressesAreAccepted() {
        #expect(SplitRuleHostInput.validate("1.2.3.4").normalized == "1.2.3.4")
        #expect(SplitRuleHostInput.validate("2001:db8::1").normalized == "2001:db8::1")
    }

    /// The matcher unmaps an ipv4-mapped ipv6 address before keying on it, so
    /// storing the mapped form would key something the matcher never looks up.
    @Test func mappedAddressesAreUnmapped() {
        #expect(SplitRuleHostInput.validate("::ffff:1.2.3.4").normalized == "1.2.3.4")
    }

    /// Go masks a prefix before matching, so an unmasked one is silently
    /// rewritten there. Doing it here means the chip shows what is in force.
    @Test func rangesAreMaskedToTheirNetwork() {
        let validation = SplitRuleHostInput.validate("192.168.1.42/24")
        #expect(validation.normalized == "192.168.1.0/24")
        #expect(validation.note == "192.168.1.0/24")
    }

    @Test func alreadyMaskedRangesCarryNoNote() {
        let validation = SplitRuleHostInput.validate("10.0.0.0/8")
        #expect(validation.normalized == "10.0.0.0/8")
        #expect(validation.note == nil)
    }

    @Test func malformedRangesAreRefused() {
        #expect(SplitRuleHostInput.validate("10.0.0.0/").error == .badRange)
        #expect(SplitRuleHostInput.validate("10.0.0.0/33").error == .badRange)
        #expect(SplitRuleHostInput.validate("example.com/24").error == .badRange)
        #expect(SplitRuleHostInput.validate("2001:db8::/129").error == .badRange)
    }

    @Test func anEmptyFieldIsNeitherAcceptedNorAnError() {
        let validation = SplitRuleHostInput.validate("   ")
        #expect(validation.normalized == nil)
        #expect(validation.error == nil)
        #expect(!validation.isAccepted)
    }

    @Test func duplicatesAreRefused() {
        #expect(SplitRuleHostInput.validate("example.com", existing: ["example.com"]).error == .duplicate)
        // the dedupe is against the NORMALIZED form, not the typed one
        #expect(SplitRuleHostInput.validate("EXAMPLE.com", existing: ["example.com"]).error == .duplicate)
    }

    /// The rule row collapses a bare name into a wildcard that already covers
    /// it, so adding both would show one chip where two values were typed.
    @Test func valuesAlreadyCoveredByAWildcardAreRefused() {
        #expect(SplitRuleHostInput.validate("a.example.com", existing: ["*.example.com"]).error
            == .covered(by: "*.example.com"))
        #expect(SplitRuleHostInput.validate("example.com", existing: ["**.example.com"]).error
            == .covered(by: "**.example.com"))
        // *. is subdomains only, so the bare base is not covered by it
        #expect(SplitRuleHostInput.validate("example.com", existing: ["*.example.com"]).isAccepted)
        // an unrelated name is not covered
        #expect(SplitRuleHostInput.validate("example.org", existing: ["*.example.com"]).isAccepted)
    }

    @Test func everyRejectionHasSomethingToSay() {
        let errors: [SplitRuleHostError] = [
            .notAscii, .badName, .badWildcard, .badRange, .duplicate, .covered(by: "*.example.com"),
        ]
        for error in errors {
            #expect(!SplitRuleHostInput.message(for: error).isEmpty)
        }
    }
}
