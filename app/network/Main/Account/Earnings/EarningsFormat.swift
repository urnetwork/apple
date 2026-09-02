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
}
