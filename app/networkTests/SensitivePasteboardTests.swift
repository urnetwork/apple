//
//  SensitivePasteboardTests.swift
//  networkTests
//

import Foundation
import Testing
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
@testable import URnetwork

/**
 * A copied secret (the new API key) stays on this device and leaves the
 * pasteboard on its own. Each test writes to a pasteboard of its own name,
 * never the general one. iOS: the item expires, which a copy made with a
 * clock already past its lifetime shows at once. macOS: the item is
 * concealed, and the clear it schedules runs when the test says.
 */
@MainActor
struct SensitivePasteboardTests {

    // a test-only key in the server's form, never a real one
    private static let secret = "urn_TESTONLY00000000000000000000000000000000000000000000"

    @Test func aSecretStaysForTwoMinutes() {
        #expect(SensitivePasteboard.lifetime == 2 * 60)
    }

    #if os(iOS)

    private static func pasteboard() -> UIPasteboard {
        UIPasteboard.withUniqueName()
    }

    @Test func aCopyIsOnThePasteboard() {
        let pasteboard = Self.pasteboard()
        defer {
            UIPasteboard.remove(withName: pasteboard.name)
        }
        SensitivePasteboard.copy(Self.secret, to: pasteboard, now: Date())
        #expect(pasteboard.string == Self.secret)
        #expect(pasteboard.numberOfItems == 1)
    }

    // the copy carries its expiration: one whose lifetime has passed is gone
    @Test func aCopyExpires() {
        let pasteboard = Self.pasteboard()
        defer {
            UIPasteboard.remove(withName: pasteboard.name)
        }
        let longAgo = Date().addingTimeInterval(-2 * SensitivePasteboard.lifetime)
        SensitivePasteboard.copy(Self.secret, to: pasteboard, now: longAgo)
        #expect(pasteboard.string == nil)
        #expect(!pasteboard.hasStrings)
    }

    #elseif os(macOS)

    private static func pasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("network.ur.tests.sensitive." + UUID().uuidString))
    }

    @Test func aCopyIsConcealedAndClearedAfterItsLifetime() {
        let pasteboard = Self.pasteboard()
        defer {
            pasteboard.releaseGlobally()
        }
        var delays: [TimeInterval] = []
        var clears: [@MainActor () -> Void] = []
        SensitivePasteboard.copy(Self.secret, to: pasteboard) { delay, work in
            delays.append(delay)
            clears.append(work)
        }
        #expect(pasteboard.string(forType: .string) == Self.secret)
        #expect(pasteboard.types?.contains(SensitivePasteboard.concealedType) == true)
        #expect(delays == [SensitivePasteboard.lifetime])

        for clear in clears {
            clear()
        }
        #expect(pasteboard.string(forType: .string) == nil)
    }

    // anything copied since is the user's, and stays
    @Test func somethingCopiedSinceIsNotCleared() {
        let pasteboard = Self.pasteboard()
        defer {
            pasteboard.releaseGlobally()
        }
        var clears: [@MainActor () -> Void] = []
        SensitivePasteboard.copy(Self.secret, to: pasteboard) { _, work in
            clears.append(work)
        }
        pasteboard.clearContents()
        pasteboard.setString("copied since", forType: .string)

        for clear in clears {
            clear()
        }
        #expect(pasteboard.string(forType: .string) == "copied since")
    }

    #endif
}
