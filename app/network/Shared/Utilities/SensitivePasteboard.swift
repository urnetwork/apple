//
//  SensitivePasteboard.swift
//  URnetwork
//
//  Copies a secret, such as a new API key, so that it stays on this device
//  and leaves the pasteboard on its own after `lifetime`:
//  - iOS marks the item local-only, so Universal Clipboard never sends it to
//    the user's other devices, and gives it an expiration date, after which
//    the system removes it.
//  - macOS has neither option for a pasteboard item. The copy is kept to
//    this Mac (currentHostOnly), carries the nspasteboard.org concealed
//    marker, which clipboard managers honor by neither recording nor showing
//    it, and is cleared after the same time unless something else was copied
//    since. That clear runs only while the app does.
//

import Foundation
#if os(iOS)
import UIKit
import UniformTypeIdentifiers
#elseif os(macOS)
import AppKit
#endif

enum SensitivePasteboard {

    /// How long a copied secret stays on the pasteboard.
    static let lifetime: TimeInterval = 2 * 60

    #if os(iOS)

    /// Puts `secret` on `pasteboard`, local-only and expiring `lifetime` after
    /// `now`.
    static func copy(_ secret: String, to pasteboard: UIPasteboard = .general, now: Date = Date()) {
        pasteboard.setItems(
            [[UTType.utf8PlainText.identifier: secret]],
            options: [
                .localOnly: true,
                .expirationDate: now.addingTimeInterval(lifetime),
            ]
        )
    }

    #elseif os(macOS)

    /// nspasteboard.org: the item is sensitive, so a clipboard manager
    /// neither records nor shows it
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    /// Runs `work` on the main actor after `delay` seconds. Tests pass one
    /// that runs when they say.
    typealias Schedule = (_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> Void

    static func scheduleOnMainQueue(_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated {
                work()
            }
        }
    }

    /// Puts `secret` on `pasteboard` for this Mac only, concealed, and clears
    /// it after `lifetime` unless something else was copied since.
    @MainActor
    static func copy(_ secret: String, to pasteboard: NSPasteboard = .general, schedule: Schedule = scheduleOnMainQueue) {
        _ = pasteboard.prepareForNewContents(with: .currentHostOnly)
        pasteboard.setString(secret, forType: .string)
        pasteboard.setData(Data(), forType: concealedType)
        let written = pasteboard.changeCount
        schedule(lifetime) {
            // anything copied since is the user's, and stays
            if pasteboard.changeCount == written {
                pasteboard.clearContents()
            }
        }
    }

    #endif
}
