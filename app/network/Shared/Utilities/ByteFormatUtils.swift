//
//  ByteFormatUtils.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 7/5/25.
//

import Foundation

func formatMiB(mib: Float) -> String {

    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.maximumFractionDigits = 2
    
    let pib: Float = 1024 * 1024 * 1024
    let tib: Float = 1024 * 1024
    let gib: Float = 1024

    // 1 GiB = 1024 MiB
    // if mib >= 1_048_576 {  // 1 PiB = 1024 TiB = 1,048,576 GiB
    if mib >= pib {
        let pib = mib / pib
        let formatted =
            formatter.string(from: NSNumber(value: pib)) ?? String(format: "%.2f", pib)
        return "\(formatted) PiB"
    } else if mib >= tib {  // 1 TiB = 1024 GiB = 1,048,576 MiB
        let tib = mib / tib
        let formatted =
            formatter.string(from: NSNumber(value: tib)) ?? String(format: "%.2f", tib)
        return "\(formatted) TiB"
    } else if mib >= gib {  // 1 GiB = 1024 MiB
        let gib = mib / gib
        let formatted =
            formatter.string(from: NSNumber(value: gib)) ?? String(format: "%.2f", gib)
        return "\(formatted) GiB"
    } else {
        let formatted =
            formatter.string(from: NSNumber(value: mib)) ?? String(format: "%.2f", mib)
        return "\(formatted) MiB"
    }
}

func formatBalanceBytes(_ bytes: Int) -> String {
    let oneTiB = 1024 * 1024 * 1024 * 1024
    let oneGiB = 1024 * 1024 * 1024
    let doubleBytes = Double(bytes)
    if bytes >= oneTiB {
        let value = doubleBytes / Double(oneTiB)
        return String(format: "%.2f TiB", value)
    } else {
        let value = doubleBytes / Double(oneGiB)
        return String(format: "%.2f GiB", value)
    }
}
