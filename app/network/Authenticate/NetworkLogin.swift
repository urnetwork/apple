//
//  NetworkLogin.swift
//  URnetwork
//

import Foundation

/// Carries the account-creation classification with the credential that owns it.
/// A created account must not be downgraded by a duplicate callback consuming
/// process-global state before the first registration finishes.
struct NetworkLogin: Equatable, Sendable {
    let jwt: String
    let newNetwork: Bool

    static func existing(_ jwt: String) -> NetworkLogin {
        NetworkLogin(jwt: jwt, newNetwork: false)
    }

    static func created(_ jwt: String) -> NetworkLogin {
        NetworkLogin(jwt: jwt, newNetwork: true)
    }
}

typealias NetworkLoginHandler = @MainActor (_ login: NetworkLogin, _ request: NetworkLoginRequest) async -> Void
typealias NetworkLoginCredentialHandler = @MainActor (_ jwt: String, _ request: NetworkLoginRequest) async -> Void
