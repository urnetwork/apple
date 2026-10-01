//
//  NetworkServerSheetViewModel.swift
//  URnetwork
//
//  ViewModel for `NetworkServerSheet`, the "Change Network API" sheet that
//  lets a user point the app at a different network (self-hosted or
//  alternate) instead of the official bringyour.com. Ported from Android's
//  `NetworkServerSelector.kt`.
//

import Foundation
import SwiftUI

extension NetworkServerSheet {

    @MainActor
    class ViewModel: ObservableObject {

        @Published var hostName: String
        @Published var apiUrl: String
        @Published var connectUrl: String
        @Published private(set) var statusMessage: String?

        let officialHostName: String
        let envName: String

        init(
            initialHostName: String,
            configuredApiUrl: String,
            configuredConnectUrl: String,
            officialHostName: String = NetworkConfig.officialHostName,
            envName: String = NetworkConfig.officialEnvName
        ) {
            let normalizedInitial = NetworkServerUtils.normalizeNetworkHost(initialHostName)
            self.hostName = normalizedInitial.isEmpty ? officialHostName : normalizedInitial
            self.apiUrl = configuredApiUrl
            self.connectUrl = configuredConnectUrl
            self.officialHostName = officialHostName
            self.envName = envName
        }

        var normalizedHostName: String {
            NetworkServerUtils.normalizeNetworkHost(hostName)
        }

        var isOfficialHost: Bool {
            let normalizedOfficial = NetworkServerUtils.normalizeNetworkHost(officialHostName)
            return normalizedHostName == normalizedOfficial
        }

        var derivedApiUrl: String {
            let host = normalizedHostName.isEmpty ? officialHostName : normalizedHostName
            return NetworkServerUtils.derivedServiceUrl(
                hostName: host,
                migrationHostName: "",
                envName: envName,
                scheme: "https",
                service: "api"
            )
        }

        var derivedConnectUrl: String {
            let host = normalizedHostName.isEmpty ? officialHostName : normalizedHostName
            return NetworkServerUtils.derivedServiceUrl(
                hostName: host,
                migrationHostName: "",
                envName: envName,
                scheme: "wss",
                service: "connect"
            )
        }

        var showInsecureEndpointWarning: Bool {
            (!apiUrl.isEmpty && NetworkServerUtils.hasInsecureScheme(apiUrl, secureScheme: "https")) ||
                (!connectUrl.isEmpty && NetworkServerUtils.hasInsecureScheme(connectUrl, secureScheme: "wss"))
        }

        func resetToDefault() -> (hostName: String, apiUrl: String, connectUrl: String) {
            hostName = officialHostName
            apiUrl = ""
            connectUrl = ""
            return (officialHostName, "", "")
        }

        func setStatusMessage(_ message: String?) {
            statusMessage = message
        }
    }
}
