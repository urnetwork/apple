//
//  PostQuantumIdentityStore.swift
//  URnetwork
//
//  Created by Brien Colwell on 7/21/26.
//

import Foundation
import SwiftUI
import URnetworkSdk

/**
 * The canonical identity key hash display rule, shared by every platform:
 * split the 52-char hash into 4-char groups and show the first 4 groups, an
 * ellipsis, then the last 2 groups. Copy always uses the full un-grouped
 * hash, never this display form.
 */
func formatIdentityKeyHashForDisplay(_ hash: String) -> String {
    var groups: [String] = []
    var i = hash.startIndex
    while i < hash.endIndex {
        let end = hash.index(i, offsetBy: 4, limitedBy: hash.endIndex) ?? hash.endIndex
        groups.append(String(hash[i..<end]))
        i = end
    }
    guard 6 < groups.count else {
        return groups.joined(separator: " ")
    }
    return (groups.prefix(4) + ["…"] + groups.suffix(2)).joined(separator: " ")
}

/**
 * The full grouped hash for the share view: every 4-char group, nothing
 * truncated — the share dialog exists for reading, screenshots, and
 * side-channel verification.
 */
func formatIdentityKeyHashForShare(_ hash: String) -> String {
    var groups: [String] = []
    var i = hash.startIndex
    while i < hash.endIndex {
        let end = hash.index(i, offsetBy: 4, limitedBy: hash.endIndex) ?? hash.endIndex
        groups.append(String(hash[i..<end]))
        i = end
    }
    return groups.joined(separator: " ")
}

/**
 * One identity row: a provider with an established, identity-verified e2e
 * session (the provider identities list and the panel deck), and also the
 * device's own identity on the panel's top row — same shape, same layout.
 */
struct ProviderIdentityRow: Identifiable, Equatable {
    let clientId: String
    let publicKeyHash: String
    // the raw public identity key, for share-time rendering of the
    // canonical identicon png
    let publicKey: Data
    // list-row size raster
    let identicon: IdenticonImage?
    // panel-deck size raster
    let identiconSmall: IdenticonImage?
    // badge-size raster, rendered next to the client id in provider
    // locations to mark a provider with a verified e2e session
    let identiconBadge: IdenticonImage?

    var id: String { clientId }

    // the identicons derive from the public key, which the hash captures, and
    // are cached per (key, size) -- so value equality is the ids and the hash
    static func == (lhs: ProviderIdentityRow, rhs: ProviderIdentityRow) -> Bool {
        lhs.clientId == rhs.clientId && lhs.publicKeyHash == rhs.publicKeyHash
    }
}

private class PostQuantumIdentityChangeListener: NSObject, SdkPostQuantumIdentityListenerProtocol {
    private let callback: () -> Void
    init(callback: @escaping () -> Void) {
        self.callback = callback
    }
    func providerIdentitiesChanged() {
        callback()
    }
}

/**
 * Publishes the device's own public identity key (identicon + canonical
 * hash) and the live providers with an identity-verified e2e session. The
 * state comes from the SDK PostQuantumIdentityViewController, shared by
 * every platform; this store maps it onto UI types and re-reads on every
 * `providerIdentitiesChanged`.
 */
@MainActor
class PostQuantumIdentityStore: ObservableObject {

    // identicon display point sizes; rasters render at 2x
    // the provider-locations trailing badge next to the 11pt client id
    static let badgeIdenticonSize: CGFloat = 16
    static let deckIdenticonSize: CGFloat = 28
    static let rowIdenticonSize: CGFloat = 40
    // the panel's own-identity identicon: 2x a list row
    static let panelIdenticonSize: CGFloat = 80
    // the share dialog identicon: 4x the panel, sized for screenshots
    static let shareIdenticonSize: CGFloat = 320

    // the device's own identity (key hash + identicon + client id), shaped
    // like a provider identities row so the panel renders it identically
    @Published private(set) var ownIdentityRow: ProviderIdentityRow? = nil

    // providers with an established, identity-verified e2e session
    @Published private(set) var providerIdentities: [ProviderIdentityRow] = []

    private var device: SdkDeviceRemote?
    private var viewController: SdkPostQuantumIdentityViewController?
    private var identitiesSub: SdkSubProtocol?

    // identicon raster cache, keyed by (key hash, point size)
    private var identiconCache: [String: IdenticonImage] = [:]

    func setup(_ device: SdkDeviceRemote) {
        reset()

        self.device = device
        let vc = device.openPostQuantumIdentityViewController()
        self.viewController = vc
        self.identitiesSub = vc?.add(PostQuantumIdentityChangeListener { [weak self] in
            DispatchQueue.main.async {
                self?.update()
            }
        })
        // start seeds the listener with the current state
        vc?.start()
        update()
    }

    func reset() {
        identitiesSub?.close()
        identitiesSub = nil
        if let viewController {
            if let device {
                device.close(viewController)
            } else {
                viewController.close()
            }
        }
        viewController = nil
        device = nil
        ownIdentityRow = nil
        providerIdentities = []
        identiconCache = [:]
    }

    private func identicon(key: Data, hash: String, size: CGFloat) -> IdenticonImage? {
        let cacheKey = "\(hash):\(Int(size))"
        if let image = identiconCache[cacheKey] {
            return image
        }
        guard let image = IdenticonView.renderImage(key: key, size: size) else {
            return nil
        }
        identiconCache[cacheKey] = image
        return image
    }

    private func update() {
        guard let vc = self.viewController else {
            return
        }

        let hash = vc.getPublicIdentityKeyHash()
        var ownRow: ProviderIdentityRow? = nil
        if let key = vc.getPublicIdentityKey(), !hash.isEmpty {
            ownRow = ProviderIdentityRow(
                clientId: device?.getClientId()?.idStr ?? "",
                publicKeyHash: hash,
                publicKey: key,
                identicon: identicon(key: key, hash: hash, size: Self.panelIdenticonSize),
                identiconSmall: nil,
                identiconBadge: nil
            )
        }
        if ownRow != ownIdentityRow {
            ownIdentityRow = ownRow
        }

        var rows: [ProviderIdentityRow] = []
        if let list = vc.getProviderIdentities() {
            for i in 0..<list.len() {
                guard let identity = list.get(i),
                      let clientId = identity.clientId,
                      let key = identity.publicKey else {
                    continue
                }
                let keyHash = identity.getPublicKeyHash()
                rows.append(
                    ProviderIdentityRow(
                        clientId: clientId.idStr,
                        publicKeyHash: keyHash,
                        publicKey: key,
                        identicon: identicon(key: key, hash: keyHash, size: Self.rowIdenticonSize),
                        identiconSmall: identicon(key: key, hash: keyHash, size: Self.deckIdenticonSize),
                        identiconBadge: identicon(key: key, hash: keyHash, size: Self.badgeIdenticonSize)
                    )
                )
            }
        }
        if rows != providerIdentities {
            withAnimation(.easeInOut(duration: 0.25)) {
                providerIdentities = rows
            }
        }
    }
}
