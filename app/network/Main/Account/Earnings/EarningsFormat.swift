//
//  EarningsFormat.swift
//  URnetwork
//
//  Formatting for the subnet layer of the Earnings screen. The SDK owns the
//  canonical formatters (SdkFormatAlpha and friends); these wrap them so the
//  views read plainly and previews work without a device.
//

import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

enum SnAlpha {

    /// the subnet token symbol, never translated
    static let symbol = "SN25α"

    /// 1 α = 1e9 rao
    static let raoPerAlpha: Double = 1_000_000_000

    /// "3.2410 SN25α"
    static func format(rao: Int64) -> String {
        let alpha = Double(rao) / raoPerAlpha
        return String(format: "%.4f %@", alpha, symbol)
    }

    /// "3.2410" (no symbol), for rows that carry the symbol in a header
    static func formatAmount(rao: Int64) -> String {
        String(format: "%.4f", Double(rao) / raoPerAlpha)
    }

    /// "0.71%"
    static func formatShareBps(_ shareBps: Int64) -> String {
        String(format: "%.2f%%", Double(shareBps) / 100.0)
    }

    /// "5F3s…kQ9v"
    static func shortSs58(_ address: String) -> String {
        guard address.count > 12 else { return address }
        return "\(address.prefix(4))…\(address.suffix(4))"
    }

    /// Local syntax check of a Bittensor (ss58 prefix 42) address: base58
    /// alphabet, the length of a 32-byte account id with prefix and checksum.
    /// The chain-side checks come from the wallet validation endpoint.
    static func looksLikeSs58(_ address: String) -> Bool {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 47, trimmed.count <= 48 else { return false }
        let alphabet = Set("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")
        return trimmed.allSatisfy { alphabet.contains($0) }
    }

    static func formatTao(_ tao: Double) -> String {
        String(format: "%.4f TAO", tao)
    }

    /// "0.0125" (no symbol): an amount in rao of TAO, for a sentence that
    /// names TAO itself
    static func formatTaoAmount(rao: Int64) -> String {
        String(format: "%.4f", Double(rao) / raoPerAlpha)
    }

    /// "3", "1.5" or "0.0420" (no symbol): an estimate, as precise as its size
    /// needs, for "about 3 SN25α"
    static func formatApprox(rao: Int64) -> String {
        let value = Double(rao) / raoPerAlpha
        if 10 <= value {
            return String(format: "%.0f", value)
        }
        if 1 <= value {
            return String(format: "%.1f", value)
        }
        return String(format: "%.4f", value)
    }

    static func formatPoints(_ points: Double) -> String {
        points.formatted(.number.precision(.fractionLength(0...2)).grouping(.automatic))
    }

    static func epochRange(startMillis: Int64, endMillis: Int64) -> String {
        let start = Date(timeIntervalSince1970: Double(startMillis) / 1000)
        let end = Date(timeIntervalSince1970: Double(endMillis) / 1000)
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        if startMillis <= 0 || endMillis <= 0 {
            return ""
        }
        return "\(formatter.string(from: start)) – \(formatter.string(from: end))"
    }
}

enum EarningsClipboard {
    static func copy(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }

    /// The clipboard's text, or nil.
    static func paste() -> String? {
        #if canImport(UIKit)
        return UIPasteboard.general.string
        #elseif canImport(AppKit)
        return NSPasteboard.general.string(forType: .string)
        #else
        return nil
        #endif
    }
}
