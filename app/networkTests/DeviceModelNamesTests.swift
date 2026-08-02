//
//  DeviceModelNamesTests.swift
//  networkTests
//
//  Covers the generated hardware-identifier -> retail-name table behind the
//  device spec ("18.5 iPhone 16 Pro Max"). Known identifiers resolve across
//  the ios, ipad, and mac catalogs; unknown (newer-than-table) identifiers
//  return nil so the caller falls back to the identifier itself.
//

import Testing
@testable import URnetwork

struct DeviceModelNamesTests {

    @Test func knownIdentifiersResolve() {
        #expect(DeviceModelNames.name(forIdentifier: "iPhone17,2") == "iPhone 16 Pro Max")
        #expect(DeviceModelNames.name(forIdentifier: "iPhone16,2") == "iPhone 15 Pro Max")
        #expect(DeviceModelNames.name(forIdentifier: "iPad16,6") == "iPad Pro 13-inch (M4)")
        #expect(DeviceModelNames.name(forIdentifier: "Mac15,7") == "MacBook Pro (16-inch, Nov 2023)")
    }

    @Test func unknownIdentifiersFallBack() {
        #expect(DeviceModelNames.name(forIdentifier: "iPhone99,9") == nil)
        #expect(DeviceModelNames.name(forIdentifier: "") == nil)
    }

    @Test func simulatorArchitectureResolves() {
        #expect(DeviceModelNames.name(forIdentifier: "arm64") == "iPhone Simulator")
        #expect(DeviceModelNames.name(forIdentifier: "x86_64") == "iPhone Simulator")
    }
}
