//
//  AccountViewModel.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2024/12/10.
//

import Foundation
import URnetworkSdk

/// How a link opens an account page in the phone's stack.
enum AccountNavigationPaths {

    /// Back to `path` when the stack already shows it (Claim on Earnings
    /// with Earnings and its Sign fleet binding open lands on Earnings,
    /// rather than a second Earnings over them); else pushed.
    static func opening(_ path: AccountNavigationPath, in stack: [AccountNavigationPath]) -> [AccountNavigationPath] {
        if let index = stack.firstIndex(of: path) {
            return Array(stack.prefix(through: index))
        }
        return stack + [path]
    }
}

enum AccountNavigationPath: Hashable {
    case profile
    case sessions
    case apiKeys
    case settings
    case earnings
    /// Earnings › Top 200 › Sign fleet binding, with the app link that opened it, if any
    case top200Sign(Top200SignDestination?)
    case referrals
    case widgets
    case extenders
    case vless
    case blockedLocations
    case transferBalanceCodes
    case providerContracts
    case providerIdentities
    case developer
    case licenses
    case licenseDetail(LicenseEntry)
}

extension AccountNavStackView {
    
    class ViewModel: ObservableObject {
        
        // the one path both layouts show: the phone's stack, and in a
        // regular-width window the screen chosen from the list (its first
        // screen) with what that screen opened, so a fold or a resize keeps
        // the screen and its place
        @Published var navigationPath: [AccountNavigationPath] = []
        
        func navigate(_ path: AccountNavigationPath) {
            navigationPath.append(path)
        }

        /// A link's page in the phone's stack: back to it when the stack
        /// already shows it, else pushed (AccountNavigationPaths.opening).
        func open(_ path: AccountNavigationPath) {
            let opened = AccountNavigationPaths.opening(path, in: navigationPath)
            if opened != navigationPath {
                navigationPath = opened
            }
        }

        /// A row of the list beside the chosen screen: it replaces the
        /// chosen screen and whatever that screen opened.
        func select(_ path: AccountNavigationPath) {
            navigationPath = [path]
        }

        /// The screen chosen from the list, beside it.
        var selection: AccountNavigationPath? {
            navigationPath.first
        }

        /// The screens the chosen screen opened, stacked over it.
        var detailPath: [AccountNavigationPath] {
            get {
                Array(navigationPath.dropFirst())
            }
            set {
                let path = Array(navigationPath.prefix(1)) + newValue
                // an unchanged path publishes nothing, so the detail stack
                // writing back what it shows cannot loop
                if path != navigationPath {
                    navigationPath = path
                }
            }
        }

        func back() {
            if !navigationPath.isEmpty {
             navigationPath.removeLast()
            }
        }
        
    }
    
}
