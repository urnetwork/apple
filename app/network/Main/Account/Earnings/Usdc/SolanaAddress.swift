//
//  SolanaAddress.swift
//  URnetwork
//
//  The server's rule for a Solana payout address (chain SOL on
//  POST /wallet/validate-address and POST /account/wallet): base58 that
//  decodes to exactly 32 bytes, not all zero and not the USDC mint. The
//  connect flow applies it before any request, so an address the server would
//  refuse is answered at once and never sent. The server stays the authority;
//  it checks a key a wallet app hands back when the wallet is created.
//

import Foundation

enum SolanaAddress {

    /// the USDC token mint: a token, never a wallet
    static let usdcMint = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"

    private static let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz".utf8)

    /// The address is trimmed first, as the flow sends it.
    static func isValid(_ address: String) -> Bool {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        // 32 bytes take 32 to 44 characters; the bound also keeps the decode small
        guard (32...44).contains(trimmed.utf8.count),
              trimmed != usdcMint,
              let bytes = decodeBase58(trimmed),
              bytes.count == 32 else {
            return false
        }
        return bytes.contains { $0 != 0 }
    }

    /// A zero byte for each leading "1", then the number the rest spells, in
    /// as few bytes as it takes; nil when a character is not in the alphabet.
    static func decodeBase58(_ text: String) -> [UInt8]? {
        let zeros = text.utf8.prefix(while: { $0 == alphabet[0] }).count
        // least significant byte first
        var number: [UInt8] = []
        for character in text.utf8 {
            guard let digit = alphabet.firstIndex(of: character) else {
                return nil
            }
            var carry = digit
            for i in number.indices {
                carry += Int(number[i]) * 58
                number[i] = UInt8(carry & 0xff)
                carry >>= 8
            }
            while carry > 0 {
                number.append(UInt8(carry & 0xff))
                carry >>= 8
            }
        }
        return [UInt8](repeating: 0, count: zeros) + number.reversed()
    }
}
