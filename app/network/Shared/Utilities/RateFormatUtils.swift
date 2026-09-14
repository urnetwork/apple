//
//  RateFormatUtils.swift
//  URnetwork
//
//  Created by Brien Colwell on 7/8/26.
//

import Foundation

/**
 * Compact byte count, e.g. "996 B", "1.2 KiB", "3.4 MiB", "1.1 GiB"
 */
func formatByteCountCompact(_ byteCount: Int64) -> String {
    let kib = 1024.0
    let mib = kib * 1024
    let gib = mib * 1024
    let tib = gib * 1024

    let v = Double(byteCount)

    func fmt(_ value: Double, _ unit: String) -> String {
        if value >= 100 {
            return String(format: "%.0f %@", value, unit)
        } else if value >= 10 {
            return String(format: "%.1f %@", value, unit)
        } else {
            return String(format: "%.2f %@", value, unit)
        }
    }

    if v < kib {
        return "\(byteCount) B"
    } else if v < mib {
        return fmt(v / kib, "KiB")
    } else if v < gib {
        return fmt(v / mib, "MiB")
    } else if v < tib {
        return fmt(v / gib, "GiB")
    } else {
        return fmt(v / tib, "TiB")
    }
}

/**
 * Compact byte rate, e.g. "1.2 KiB/s"
 */
func formatByteRate(_ bytesPerSecond: Int64) -> String {
    return formatByteCountCompact(bytesPerSecond) + "/s"
}

/**
 * Compact count, e.g. "996", "1.2k", "3.4M"
 */
func formatCountCompact(_ count: Int64) -> String {
    let v = Double(count)
    if count < 1000 {
        return "\(count)"
    } else if v < 1_000_000 {
        return String(format: v < 10_000 ? "%.1fk" : "%.0fk", v / 1000)
    } else {
        return String(format: "%.1fM", v / 1_000_000)
    }
}

/**
 * Compact packet rate, e.g. "340 pkt/s"
 */
func formatPacketRate(_ packetsPerSecond: Int64) -> String {
    return formatCountCompact(packetsPerSecond) + " pkt/s"
}

/**
 * Compact read rate, e.g. "340 reads/s": the count label of the extender
 * chart, since the extender relays byte streams and counts the chunks it
 * moves rather than packets (EXTENDER.md O1, O8)
 */
func formatReadRate(_ readsPerSecond: Int64) -> String {
    return formatCountCompact(readsPerSecond) + " " + String(localized: "reads/s")
}

/**
 * Compact bit rate, e.g. "1.2 Mbps"
 */
func formatBitRate(_ bitsPerSecond: Int) -> String {
    let v = Double(bitsPerSecond)

    func fmt(_ value: Double, _ unit: String) -> String {
        if value >= 100 {
            return String(format: "%.0f %@", value, unit)
        } else if value >= 10 {
            return String(format: "%.1f %@", value, unit)
        } else {
            return String(format: "%.2f %@", value, unit)
        }
    }

    if v < 1000 {
        return "\(bitsPerSecond) bps"
    } else if v < 1_000_000 {
        return fmt(v / 1000, "Kbps")
    } else if v < 1_000_000_000 {
        return fmt(v / 1_000_000, "Mbps")
    } else {
        return fmt(v / 1_000_000_000, "Gbps")
    }
}
