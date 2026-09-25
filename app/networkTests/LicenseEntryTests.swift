//
//  LicenseEntryTests.swift
//  networkTests
//
//  Covers the copy Account > Settings > Licenses renders from: the apple list
//  the SDK embeds, read without a device.
//

import Testing
import URnetworkSdk
@testable import URnetwork

struct LicenseEntryTests {

    @Test func loadsTheAppleList() {
        let entries = LicenseEntry.load(device: nil)
        #expect(!entries.isEmpty)
        #expect(Set(entries.map(\.id)).count == entries.count)
    }

    /// the MaxMind attribution is a license requirement: it must be the first
    /// entry and carry its notice
    @Test func geoLite2NoticeComesFirst() throws {
        let first = try #require(LicenseEntry.load(device: nil).first)
        #expect(first.isData)
        #expect(first.name.contains("GeoLite2"))
        #expect(!first.notice.isEmpty)
    }

    /// the screen splits on kind; data attributions come before everything else
    @Test func dataAttributionsPrecedeSoftware() {
        let kinds = LicenseEntry.load(device: nil).map(\.isData)
        if let firstSoftware = kinds.firstIndex(of: false) {
            #expect(!kinds[firstSoftware...].contains(true))
        }
    }

    @Test func summaryOmitsEmptyParts() {
        let entries = LicenseEntry.load(device: nil)
        for entry in entries {
            #expect(!entry.summary.hasPrefix(" · "))
            #expect(!entry.summary.hasSuffix(" · "))
        }
    }
}
