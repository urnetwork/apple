//
//  SolanaAddressTests.swift
//  networkTests
//
//  The server's rule for a Solana payout address, which the app now applies
//  before an address is sent (support inbox 8045). The keys are synthetic: the
//  base58 of visible byte patterns.
//

import Testing
@testable import URnetwork

struct SolanaAddressTests {

    /// the bytes 01 02 … 20
    private static let ascendingKey = "4wBqpZM9xaSheZzJSMawUKKwhdpChKbZ5eu5ky4Vigw"
    /// two zero bytes, then 01 02 … 1e: each zero byte is a leading "1"
    private static let leadingZerosKey = "11CiMQsCUhqABwwLyCFeX2iPnBZX3s28dUUCBrirhs"

    @Test func aKeyOf32BytesPasses() {
        #expect(SolanaAddress.decodeBase58(Self.ascendingKey) == [UInt8](1...32))
        #expect(SolanaAddress.isValid(Self.ascendingKey))
        #expect(SolanaAddress.decodeBase58(Self.leadingZerosKey) == [0, 0] + [UInt8](1...30))
        #expect(SolanaAddress.isValid(Self.leadingZerosKey))
        // trimmed, as the flow sends it
        #expect(SolanaAddress.isValid(" \(Self.ascendingKey)\n"))
    }

    @Test func whatTheServerRefusesIsRefused() {
        let refused = [
            // the USDC token mint
            "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v",
            // the all-zero key
            "11111111111111111111111111111111",
            // 44 characters of base58 that decode to 33 bytes
            String(repeating: "z", count: 44),
            // a leading "1" too many or too few: 33 and 31 bytes
            "1" + Self.ascendingKey,
            String(Self.leadingZerosKey.dropFirst()),
            // a Polygon address
            "0x1234567812345678123456781234567812345678",
            // "l" is not in the alphabet
            String(Self.ascendingKey.dropLast()) + "l",
            "",
        ]
        for address in refused {
            #expect(!SolanaAddress.isValid(address), "\(address)")
        }
        #expect(SolanaAddress.decodeBase58(String(repeating: "z", count: 44))?.count == 33)
        #expect(SolanaAddress.decodeBase58("0x1234567812345678123456781234567812345678") == nil)
    }
}
