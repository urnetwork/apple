//
//  InstalledApplicationCatalogTests.swift
//  networkTests
//
//  The macOS split tunnel picker lists the apps in /Applications by the
//  identifier the extension matches. These pin how a bundle's Info.plist
//  and signature become an entry, which apps the list leaves out, its order
//  and its search (network/Shared/SplitTunnel/InstalledApplicationCatalog.swift;
//  the filesystem walk itself is macOS only).
//

import Testing
import Foundation
@testable import URnetwork

struct InstalledApplicationCatalogTests {

    private func app(_ identifier: String, name: String, bundle: String? = nil) -> InstalledApplication {
        InstalledApplication(
            identifier: identifier,
            bundleIdentifier: bundle ?? identifier,
            name: name,
            path: "/Applications/\(name).app"
        )
    }

    // MARK: entries

    @Test func theSigningIdentifierIsWhatAnEntryMatches() throws {
        let entry = try #require(InstalledApplicationCatalog.application(
            infoDictionary: ["CFBundleIdentifier": "com.example.bank", "CFBundleName": "Bank"],
            signingIdentifier: "com.example.Bank",
            path: "/Applications/Bank.app"
        ))
        #expect(entry.identifier == "com.example.Bank")
        #expect(entry.bundleIdentifier == "com.example.bank")
        #expect(entry.name == "Bank")
    }

    @Test func anUnreadableSignatureFallsBackToTheBundleIdentifier() throws {
        for signing in [nil, "", "not an identifier"] as [String?] {
            let entry = try #require(InstalledApplicationCatalog.application(
                infoDictionary: ["CFBundleIdentifier": "com.example.Bank"],
                signingIdentifier: signing,
                path: "/Applications/Bank.app"
            ))
            #expect(entry.identifier == "com.example.Bank")
        }
    }

    @Test func aBundleWithNoUsableIdentifierIsLeftOut() {
        #expect(InstalledApplicationCatalog.application(
            infoDictionary: ["CFBundleName": "Mystery"],
            signingIdentifier: nil,
            path: "/Applications/Mystery.app"
        ) == nil)
        #expect(InstalledApplicationCatalog.application(
            infoDictionary: ["CFBundleIdentifier": "bad id"],
            signingIdentifier: "",
            path: "/Applications/Mystery.app"
        ) == nil)
    }

    @Test func theNameIsTheDisplayNameThenTheBundleNameThenTheFileName() throws {
        let display = try #require(InstalledApplicationCatalog.application(
            infoDictionary: ["CFBundleIdentifier": "a.b.c", "CFBundleDisplayName": "Display", "CFBundleName": "Name"],
            signingIdentifier: nil,
            path: "/Applications/File.app"
        ))
        #expect(display.name == "Display")
        let bundleName = try #require(InstalledApplicationCatalog.application(
            infoDictionary: ["CFBundleIdentifier": "a.b.c", "CFBundleDisplayName": " ", "CFBundleName": "Name"],
            signingIdentifier: nil,
            path: "/Applications/File.app"
        ))
        #expect(bundleName.name == "Name")
        let fileName = try #require(InstalledApplicationCatalog.application(
            infoDictionary: ["CFBundleIdentifier": "a.b.c"],
            signingIdentifier: nil,
            path: "/Applications/Utilities/File Name.app"
        ))
        #expect(fileName.name == "File Name")
    }

    // MARK: the list

    @Test func theListLeavesOutThisAppAndItsExtensions() {
        let catalog = InstalledApplicationCatalog.catalog(
            [
                app("com.example.vpn", name: "VPN"),
                app("ABCDE12345.com.example.vpn.splittunnel", name: "Odd", bundle: "com.example.vpn.splittunnel"),
                app("com.example.Bank", name: "Bank"),
            ],
            excluding: ["com.example.vpn", "com.example.vpn.extension", "COM.EXAMPLE.VPN.SPLITTUNNEL"]
        )
        #expect(catalog.map(\.identifier) == ["com.example.Bank"])
    }

    @Test func theListIsUniqueAndSortedTheWayFinderSorts() {
        let catalog = InstalledApplicationCatalog.catalog(
            [
                app("com.example.zoo", name: "zoo"),
                app("com.example.App10", name: "App 10"),
                app("com.example.App2", name: "App 2"),
                app("com.example.bank", name: "Bank"),
                app("COM.EXAMPLE.BANK", name: "Bank (copy)"),
            ],
            excluding: []
        )
        #expect(catalog.map(\.name) == ["App 2", "App 10", "Bank", "zoo"])
    }

    @Test func searchMatchesEveryWordInTheNameOrIdentifier() {
        let catalog = [
            app("com.example.acme.chat2", name: "Acme Chat"),
            app("com.example.acme.Writer", name: "Acme Writer"),
            app("example.meet.xos", name: "meet.example"),
            app("com.example.coffee", name: "Café"),
        ]
        #expect(InstalledApplicationCatalog.search(catalog, query: "").count == 4)
        #expect(InstalledApplicationCatalog.search(catalog, query: "  ").count == 4)
        #expect(InstalledApplicationCatalog.search(catalog, query: "acme").map(\.name) == ["Acme Chat", "Acme Writer"])
        #expect(InstalledApplicationCatalog.search(catalog, query: "acm CHAT").map(\.name) == ["Acme Chat"])
        #expect(InstalledApplicationCatalog.search(catalog, query: "xos").map(\.name) == ["meet.example"])
        #expect(InstalledApplicationCatalog.search(catalog, query: "cafe").map(\.name) == ["Café"])
        #expect(InstalledApplicationCatalog.search(catalog, query: "bank").isEmpty)
    }

    @Test func anAppRuleFindsItsInstalledAppByEitherIdentifier() {
        let catalog = [app("com.example.Signed", name: "Signed", bundle: "com.example.bundle")]
        #expect(InstalledApplicationCatalog.application(for: "com.example.signed", in: catalog)?.name == "Signed")
        #expect(InstalledApplicationCatalog.application(for: "COM.EXAMPLE.BUNDLE", in: catalog)?.name == "Signed")
        #expect(InstalledApplicationCatalog.application(for: "com.example.gone", in: catalog) == nil)
    }
}
