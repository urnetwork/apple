//
//  NetworkConfigTests.swift
//  networkTests
//
//  The bundled official network space. The operator stays bringyour.com (the
//  move to *.ur.network was cancelled), so the official key is bringyour.com /
//  main with NO migration host, the link host stays ur.io, and ur.network
//  survives only as the legacy key that NetworkSpaceStartup migrates from.
//

import Testing
@testable import URnetwork

struct NetworkConfigTests {

    @Test func officialSpaceIsBringYourWithNoMigrationHost() {
        #expect(NetworkConfig.officialHostName == "bringyour.com")
        #expect(NetworkConfig.officialEnvName == "main")
        #expect(NetworkConfig.officialLinkHostName == "ur.io")
        #expect(NetworkConfig.legacyOfficialHostName == "ur.network")
        #expect(NetworkConfig.legacyOfficialHostName != NetworkConfig.officialHostName)
    }

    @Test func startupKeysNameTheLegacyAndOfficialSpaces() {
        #expect(NetworkSpaceStartup.legacyBundledKey?.hostName == "ur.network")
        #expect(NetworkSpaceStartup.legacyBundledKey?.envName == "main")
        #expect(NetworkSpaceStartup.bundledKey?.hostName == "bringyour.com")
        #expect(NetworkSpaceStartup.bundledKey?.envName == "main")
    }

    @MainActor
    @Test func serverSheetDerivesTheOfficialUrlsFromBringYourDirectly() {
        // the sheet's placeholders and reset target: no migration host rewrites
        // the service names any more
        let viewModel = NetworkServerSheet.ViewModel(
            initialHostName: "",
            configuredApiUrl: "",
            configuredConnectUrl: ""
        )
        #expect(viewModel.hostName == "bringyour.com")
        #expect(viewModel.officialHostName == "bringyour.com")
        #expect(viewModel.isOfficialHost)
        #expect(viewModel.derivedApiUrl == "https://api.bringyour.com")
        #expect(viewModel.derivedConnectUrl == "wss://connect.bringyour.com")

        viewModel.hostName = "custom.example"
        #expect(!viewModel.isOfficialHost)
        #expect(viewModel.derivedApiUrl == "https://api.custom.example")
        #expect(viewModel.derivedConnectUrl == "wss://connect.custom.example")

        let reset = viewModel.resetToDefault()
        #expect(reset.hostName == "bringyour.com")
        #expect(reset.apiUrl.isEmpty && reset.connectUrl.isEmpty)
    }

    @MainActor
    @Test func serverSheetTreatsTheLegacyHostAsACustomServer() {
        // ur.network is no longer the official host: typing it derives
        // ur.network service names, it is not rewritten to bringyour.com
        let viewModel = NetworkServerSheet.ViewModel(
            initialHostName: "ur.network",
            configuredApiUrl: "",
            configuredConnectUrl: ""
        )
        #expect(!viewModel.isOfficialHost)
        #expect(viewModel.derivedApiUrl == "https://api.ur.network")
    }
}
