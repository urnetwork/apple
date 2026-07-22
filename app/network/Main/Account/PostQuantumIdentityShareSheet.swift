//
//  PostQuantumIdentityShareSheet.swift
//  URnetwork
//
//  Created by Brien Colwell on 7/22/26.
//

import SwiftUI
import CoreTransferable
import URnetworkSdk

/**
 * The identity share dialog: a share-size identicon (4x the panel) with the
 * full grouped key hash and client id beneath, laid out for an easy
 * screenshot — the identicon + hash + id are the complete side-channel
 * verification payload, like a QR code dialog. The share affordance shares
 * the canonical identicon png together with the hash and client id as text.
 */
struct PostQuantumIdentityShareSheet: View {

    @EnvironmentObject var themeManager: ThemeManager

    let row: ProviderIdentityRow

    // rendered once on appear at the share size
    @State private var shareIdenticon: IdenticonImage? = nil

    var body: some View {

        VStack(spacing: 0) {

            Spacer().frame(height: 32)

            Text("Post Quantum Identity")
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(themeManager.currentTheme.textMutedColor)

            Spacer().frame(height: 24)

            IdenticonView(
                image: shareIdenticon,
                size: PostQuantumIdentityStore.shareIdenticonSize
            )

            Spacer().frame(height: 24)

            // the full grouped hash: the share view is for reading and
            // screenshots, so nothing is truncated
            Text(formatIdentityKeyHashForShare(row.publicKeyHash))
                .font(.system(size: 15, weight: .medium).monospaced())
                .foregroundColor(themeManager.currentTheme.textColor)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Spacer().frame(height: 8)

            Text(row.clientId)
                .font(.system(size: 12).monospaced())
                .foregroundColor(themeManager.currentTheme.textMutedColor)
                .multilineTextAlignment(.center)

            Spacer().frame(height: 32)

            ShareLink(
                item: IdentityIdenticonTransferable(publicKey: row.publicKey),
                message: Text(verbatim: "\(row.publicKeyHash)\n\(row.clientId)"),
                preview: SharePreview(Text("Post Quantum Identity"))
            ) {
                HStack(spacing: 8) {
                    Image(systemName: "square.and.arrow.up")
                    Text("Share")
                }
            }
            .buttonStyle(.borderedProminent)

            Spacer().frame(height: 32)

        }
        .padding(.horizontal, 24)
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 560)
        #endif
        .onAppear {
            shareIdenticon = IdenticonView.renderImage(
                key: row.publicKey,
                size: PostQuantumIdentityStore.shareIdenticonSize
            )
        }

    }

}

/**
 * ShareLink payload: the canonical identicon png rendered from the raw
 * public identity key at share size — the same bytes every platform
 * produces for this key, so shared icons compare exactly.
 */
struct IdentityIdenticonTransferable: Transferable {

    let publicKey: Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { item in
            guard let png = SdkRenderIdenticonPng(
                item.publicKey,
                Int(PostQuantumIdentityStore.shareIdenticonSize * 2),
                nil
            ) else {
                throw NSError(
                    domain: "network.ur.identity",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "identicon render failed"]
                )
            }
            return png
        }
    }

}
