//
//  ConnectionRegionTests.swift
//  networkTests
//
//  The connection region (ingress country) picker: its rows, the one stored
//  value the login control and the DNS settings share, and the can't-reach
//  prompt. Fakes and a network space in a private directory; no network.
//

import Foundation
import Testing
import URnetworkSdk
@testable import URnetwork

/// One stored value, as a network space keeps it, behind any number of stores.
private final class FakeConnectionRegionSource: ConnectionRegionSource {
    let codes: [String]
    var stored = ""
    private(set) var storeCount = 0

    init(codes: [String]) {
        self.codes = codes
    }

    func regionCodes() -> [String] { codes }
    func dohUrls(_ code: String) -> [String] { code == "cn" ? ["https://223.5.5.5/dns-query"] : [] }
    func plainDnsServers(_ code: String) -> [String] { code == "cn" ? ["223.5.5.5"] : [] }
    func storedCode() -> String { stored }
    func store(_ code: String) -> String {
        storeCount += 1
        stored = codes.contains(code) ? code : ""
        return stored
    }
}

private let english = Locale(identifier: "en_US")

@MainActor
struct ConnectionRegionPickerTests {

    @Test func theRowsAreExactlyTheSdkRegionsAndUndisclosed() {
        let store = ConnectionRegionStore(locale: english)
        store.setup(FakeConnectionRegionSource(codes: ["ru", "cn", "ir"]) as ConnectionRegionSource)
        #expect(store.options.map(\.code) == ["", "cn", "ir", "ru"])
        // names come from the platform locale (e.g. "China mainland")
        let names = ["cn", "ir", "ru"].map { english.localizedString(forRegionCode: $0.uppercased())! }
        #expect(store.options.map(\.name) == ["Other / Undisclosed"] + names.sorted())
    }

    @Test func aSelectionIsTheStoredValueAndUndisclosedIsEmpty() {
        let source = FakeConnectionRegionSource(codes: ["cn", "ru"])
        let store = ConnectionRegionStore(locale: english)
        store.setup(source as ConnectionRegionSource)
        #expect(store.selectedCode == "")

        store.select("cn")
        #expect(source.stored == "cn")
        #expect(store.selectedCode == "cn")
        #expect(store.selectedName == english.localizedString(forRegionCode: "CN"))

        store.select("")
        #expect(source.stored == "")
        #expect(store.selectedName == "Other / Undisclosed")
    }

    @Test func theRowsShowTheResolversARegionUses() {
        let store = ConnectionRegionStore(locale: english)
        store.setup(FakeConnectionRegionSource(codes: ["cn", "ru"]) as ConnectionRegionSource)
        #expect(store.resolvers("cn") == ConnectionRegionResolvers(encrypted: ["https://223.5.5.5/dns-query"], plainFallback: ["223.5.5.5"]))
        #expect(store.resolvers("ru").usesDefaults)
        #expect(store.resolvers("").usesDefaults)
    }

    // the login control and the DNS settings picker are two stores over one value
    @Test func theLoginControlAndTheSettingsPickerShareOneValue() {
        let source = FakeConnectionRegionSource(codes: ["cn", "ru"])
        let login = ConnectionRegionStore(locale: english)
        let settings = ConnectionRegionStore(locale: english)
        login.setup(source as ConnectionRegionSource)
        login.select("ru")

        settings.setup(source as ConnectionRegionSource)
        #expect(settings.selectedCode == "ru")

        settings.select("cn")
        login.reload()
        #expect(login.selectedCode == "cn")
    }

    // the real sdk: the stored value persists in the network space and both
    // stores read it back; unknown is stored as ""
    @Test func theNetworkSpaceStoresTheRegion() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConnectionRegionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let key = try #require(SdkNewNetworkSpaceKey("connectionregion", "main"))
        let manager = try #require(SdkNewNetworkSpaceManager(directory.path))
        defer {
            manager.close()
        }
        let space = try #require(manager.updateNetworkSpaceValues(key, values: SdkNetworkSpaceValues()))

        let codes = controlDohStrings(SdkIngressCountryCodes())
        #expect(codes.contains("cn"))
        let login = ConnectionRegionStore(locale: english)
        login.setup(space)
        #expect(login.options.map(\.code) == [""] + login.options.dropFirst().map(\.code))
        #expect(Set(login.options.dropFirst().map(\.code)) == Set(codes))

        login.select("cn")
        let settings = ConnectionRegionStore(locale: english)
        settings.setup(manager.getNetworkSpace(key))
        #expect(settings.selectedCode == "cn")
        #expect(!settings.resolvers("cn").encrypted.isEmpty)

        settings.select("zz")
        #expect(settings.selectedCode == "")
        #expect(space.getIngressCountryCode() == "")
    }
}

@MainActor
struct CantReachUrnetworkTests {

    private func goError(_ message: String) -> Error {
        NSError(domain: "go", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    @Test func aNetworkFailureIsCantReach() {
        #expect(isCantReachUrnetworkError(goError("Post \"https://api.bringyour.com/auth/login\": dial tcp: lookup api.bringyour.com: no such host")))
        #expect(isCantReachUrnetworkError(goError("Post \"https://api.bringyour.com/auth/login\": context deadline exceeded")))
        #expect(isCantReachUrnetworkError(goError("read tcp 10.0.0.2:5000->1.2.3.4:443: connection reset by peer")))
        #expect(isCantReachUrnetworkError(URLError(.cannotFindHost)))
        #expect(isCantReachUrnetworkError(URLError(.timedOut)))
    }

    @Test func anAnswerFromThePlatformIsNot() {
        #expect(!isCantReachUrnetworkError(goError("401 Unauthorized: invalid jwt")))
        #expect(!isCantReachUrnetworkError(goError("400 Bad Request: bad user auth")))
        #expect(!isCantReachUrnetworkError(NSError(domain: "UrApiService", code: -1, userInfo: [NSLocalizedDescriptionKey: "No result found"])))
        #expect(!isCantReachUrnetworkError(URLError(.userAuthenticationRequired)))
        #expect(!isCantReachUrnetworkError(CancellationError()))
    }

    @Test func thePromptShowsOnlyForCantReachAndNeverChangesTheRegion() {
        let source = FakeConnectionRegionSource(codes: ["cn"])
        source.stored = "cn"
        let store = ConnectionRegionStore(locale: english)
        store.setup(source as ConnectionRegionSource)
        let prompt = CantReachUrnetworkPrompt()

        #expect(!prompt.report(goError("401 Unauthorized: invalid jwt")))
        #expect(!prompt.visible)

        #expect(prompt.report(goError("dial tcp: lookup api.bringyour.com: no such host")))
        #expect(prompt.visible)

        prompt.dismiss()
        #expect(!prompt.visible)
        #expect(source.storeCount == 0)
        #expect(source.stored == "cn")
        #expect(store.selectedCode == "cn")
    }
}
