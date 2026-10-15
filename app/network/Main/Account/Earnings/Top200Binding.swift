//
//  Top200Binding.swift
//  URnetwork
//
//  The Top 200 fleet binding as the ur.io page builds it and sn's
//  `provider fleet sign` prints it: one compact JSON object with exactly the
//  eleven fields of WHITEPAPER §11.4. The device signs it with its own client
//  key on the Sign fleet binding screen (Earnings › Top 200).
//
//  Everything here is pure (Foundation only), so the checks run, and are
//  tested, before any sdk call. They are the first line: the sdk (main
//  61e89201) also refuses, in the process that holds the key, a binding for
//  another device's client_id or client_key and ambiguous JSON (a duplicated
//  or case-folded key). Nothing here logs the binding or the payload, and
//  nothing is sent anywhere.
//

import Foundation

struct Top200Binding: Equatable {
    let chainId: Int64
    let netuid: Int64
    let coordinator: String
    let fleetId: String
    let hotkey: String
    let clientId: String
    let clientKey: String
    let generation: Int64
    let validFromEpoch: Int64
    let validToEpoch: Int64
    let commitmentHash: String
}

/// The field text judged for this device, in the order the checks run.
enum Top200BindingCheck: Equatable {
    /// the field is empty: nothing to judge yet
    case empty
    /// not a binding (a pasted payload, a missing field, a bad value)
    case invalid
    /// the device's client key is not available (the extension's service is
    /// not connected)
    case noKey
    /// a binding of another client id or client key
    case otherDevice
    /// this device's binding; `text` is the trimmed field, exactly what is
    /// signed and wrapped
    case valid(text: String, binding: Top200Binding)
}

enum Top200Bindings {

    /// the longest `binding` parameter an app link may carry
    static let linkMaxChars = 4096

    static let fieldNames: Set<String> = [
        "chain_id",
        "netuid",
        "coordinator",
        "fleet_id",
        "hotkey",
        "client_id",
        "client_key",
        "generation",
        "valid_from_epoch",
        "valid_to_epoch",
        "commitment_hash",
    ]

    /// The binding in `text`, or nil when it is not one: exactly the eleven
    /// fields, each spelled exactly and once (the sdk's Go decoder matches
    /// keys case-insensitively and lets a later duplicate win), no other key
    /// (a `{binding, client_signature}` payload is not a binding); the
    /// integers whole JSON numbers >= 0 with netuid <= 65535, chain_id and
    /// generation > 0 and valid_to_epoch >= valid_from_epoch; the coordinator
    /// 0x + 40 hex; fleet_id, hotkey, client_key and commitment_hash 0x + 64
    /// hex; client_id a uuid or 0x + 32 hex. Hex case is not significant.
    static func parse(_ text: String) -> Top200Binding? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let json = object as? [String: Any],
              Set(json.keys) == fieldNames,
              // JSONSerialization keeps one of duplicate keys, while the sdk's
              // Go decoder lets the last win: a doubled key could show one
              // value in review and sign another
              let keys = topLevelKeys(trimmed),
              keys.count == fieldNames.count,
              Set(keys) == fieldNames else {
            return nil
        }

        // a json integer: not a bool, not a number with a fraction or exponent
        // (JSONSerialization keeps those as doubles), not negative
        let integer = { (name: String) -> Int64? in
            guard let number = json[name] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  !CFNumberIsFloatType(number),
                  "qlisQLIS".contains(String(cString: number.objCType)) else {
                return nil
            }
            let value = number.int64Value
            guard 0 <= value, number == NSNumber(value: value) else {
                return nil
            }
            return value
        }
        let hex = { (name: String, count: Int) -> String? in
            guard let value = json[name] as? String, isHex(value, count: count) else {
                return nil
            }
            return value
        }

        guard let chainId = integer("chain_id"),
              let netuid = integer("netuid"),
              let generation = integer("generation"),
              let validFromEpoch = integer("valid_from_epoch"),
              let validToEpoch = integer("valid_to_epoch"),
              let coordinator = hex("coordinator", 40),
              let fleetId = hex("fleet_id", 64),
              let hotkey = hex("hotkey", 64),
              let clientKey = hex("client_key", 64),
              let commitmentHash = hex("commitment_hash", 64),
              let clientId = json["client_id"] as? String,
              clientIdHex(clientId) != nil else {
            return nil
        }
        guard 0 < chainId, 0 < generation, netuid <= 65535, validFromEpoch <= validToEpoch else {
            return nil
        }

        return Top200Binding(
            chainId: chainId,
            netuid: netuid,
            coordinator: coordinator,
            fleetId: fleetId,
            hotkey: hotkey,
            clientId: clientId,
            clientKey: clientKey,
            generation: generation,
            validFromEpoch: validFromEpoch,
            validToEpoch: validToEpoch,
            commitmentHash: commitmentHash
        )
    }

    /// Judges the field text for this device: a binding at all, then the
    /// device's client key available, then the binding's client_id and
    /// client_key this device's (the 16 id bytes and the key compared as
    /// lowercase hex). Only `.valid` may be signed.
    static func check(_ text: String, deviceClientId: String?, deviceClientKey: String) -> Top200BindingCheck {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return .empty
        }
        guard let binding = parse(trimmed) else {
            return .invalid
        }
        if deviceClientKey.isEmpty {
            return .noKey
        }
        guard let deviceIdHex = deviceClientId.flatMap(clientIdHex),
              clientIdHex(binding.clientId) == deviceIdHex,
              binding.clientKey.lowercased() == deviceClientKey.lowercased() else {
            return .otherDevice
        }
        return .valid(text: trimmed, binding: binding)
    }

    /// The 16 id bytes as 32 lowercase hex, from a uuid or 0x + 32 hex; else nil.
    static func clientIdHex(_ clientId: String) -> String? {
        let parts = clientId.split(separator: "-", omittingEmptySubsequences: false)
        if parts.map(\.count) == [8, 4, 4, 4, 12] && parts.allSatisfy({ $0.allSatisfy(\.isHexDigit) && $0.allSatisfy(\.isASCII) }) {
            return parts.joined().lowercased()
        }
        if isHex(clientId, count: 32) {
            return String(clientId.dropFirst(2)).lowercased()
        }
        return nil
    }

    /// The device's fleet manifest member entry,
    /// `{"client_id":"0x<32 hex>","client_key":"<client key>"}`; nil without
    /// a client id or a client key.
    static func memberEntry(deviceClientId: String?, deviceClientKey: String) -> String? {
        guard let idHex = deviceClientId.flatMap(clientIdHex), !deviceClientKey.isEmpty else {
            return nil
        }
        return "{\"client_id\":\"0x" + idHex + "\",\"client_key\":\"" + deviceClientKey + "\"}"
    }

    /// The `{binding, client_signature}` payload: the trimmed binding text as
    /// pasted, wrapped by concatenation (never re-serialized), so a page-built
    /// binding gives the bytes `provider fleet sign` prints.
    static func payload(bindingText: String, signature: String) -> String {
        return "{\"binding\":" + bindingText.trimmingCharacters(in: .whitespacesAndNewlines)
            + ",\"client_signature\":\"" + signature + "\"}"
    }

    /// The binding text an app link's `binding` parameter carries: base64url
    /// (RFC 4648 §5, no padding) of the UTF-8 binding. Nil when the parameter
    /// is missing, longer than `linkMaxChars`, not base64url, or not UTF-8.
    /// The text still goes through `check` like a paste: the link only fills
    /// the field.
    static func decodeLinkBinding(_ parameter: String?) -> String? {
        guard let parameter, !parameter.isEmpty, parameter.count <= linkMaxChars,
              parameter.unicodeScalars.allSatisfy({ scalar in
                  scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_")
              }),
              parameter.count % 4 != 1 else {
            return nil
        }
        var base64 = parameter
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64) else {
            return nil
        }
        // nil on bytes that are not UTF-8
        return String(bytes: data, encoding: .utf8)
    }

    /// The hotkey as the review shows it: the full 0x value, all 64 hex
    /// digits, never shortened, so it can be compared digit for digit with
    /// the hotkey the operator registered.
    static func reviewHotkey(_ binding: Top200Binding) -> String {
        return binding.hotkey
    }

    /// A long hex value for display: the first 10 and last 6 characters
    /// (`0x79b5562e…049664`). Not for the review's hotkey (see reviewHotkey).
    static func shortHex(_ value: String) -> String {
        if value.count <= 16 {
            return value
        }
        return String(value.prefix(10)) + "…" + String(value.suffix(6))
    }

    /// Every key of the top-level object in `text`, decoded, in order and with
    /// repeats; nil when the text is not an object. A small tokenizer pass:
    /// strings (with their escapes) are skipped whole, and a string at depth 1
    /// followed by `:` is a key.
    static func topLevelKeys(_ text: String) -> [String]? {
        let scalars = Array(text.unicodeScalars)
        var keys: [String] = []
        var depth = 0
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            switch scalar {
            case "{", "[":
                depth += 1
                index += 1
            case "}", "]":
                depth -= 1
                index += 1
            case "\"":
                var end = index + 1
                while end < scalars.count && scalars[end] != "\"" {
                    end += scalars[end] == "\\" ? 2 : 1
                }
                guard end < scalars.count else {
                    return nil
                }
                var next = end + 1
                while next < scalars.count && CharacterSet.whitespacesAndNewlines.contains(scalars[next]) {
                    next += 1
                }
                if depth == 1 && next < scalars.count && scalars[next] == ":" {
                    var literal = String.UnicodeScalarView()
                    literal.append(contentsOf: scalars[index...end])
                    guard let data = String(literal).data(using: .utf8),
                          let key = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? String else {
                        return nil
                    }
                    keys.append(key)
                }
                index = end + 1
            default:
                index += 1
            }
        }
        guard scalars.first == "{" else {
            return nil
        }
        return keys
    }

    private static func isHex(_ value: String, count: Int) -> Bool {
        guard value.hasPrefix("0x") else {
            return false
        }
        let digits = value.unicodeScalars.dropFirst(2)
        return digits.count == count && digits.allSatisfy { scalar in
            ("0"..."9").contains(scalar) || ("a"..."f").contains(scalar) || ("A"..."F").contains(scalar)
        }
    }
}

/// The sign screen's app link, `urnetwork://top200/sign?binding=<b64url>`,
/// which the ur.io Top 200 page offers as "Open in the app". It only opens the
/// screen with the binding in the field: it never signs, never skips the
/// review and never copies. `bindingText` is nil when the link's binding is
/// missing, oversized, not base64url or not UTF-8; the screen then shows
/// top200_sign_error_invalid.
struct Top200SignDestination: Hashable {
    let bindingText: String?

    static let scheme = "urnetwork"
    static let host = "top200"

    /// The destination a URL names, or nil for any other URL the app opens.
    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              url.host?.lowercased() == Self.host,
              url.pathComponents.dropFirst() == ["sign"] else {
            return nil
        }
        // the raw parameter: percent escapes are not base64url and are refused,
        // not decoded
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQueryItems ?? []
        // a repeated binding parameter is ambiguous and refused, as on the
        // other platforms, rather than taking the first or the last
        let parameters = queryItems.filter { $0.name == "binding" }
        let parameter = parameters.count == 1 ? parameters[0].value : nil
        bindingText = Top200Bindings.decodeLinkBinding(parameter)
    }

    init(bindingText: String?) {
        self.bindingText = bindingText
    }
}
