import XCTest

final class TunnelMemoryBoundsTests: XCTestCase {
    func testPacketEncoderBoundsAndRoundTripsBurst() {
        let packets = (0..<140).map { index in
            var packet = Data(
                repeating: UInt8(index & 0xff),
                count: index.isMultiple(of: 3) ? 32 : 2_000
            )
            packet[0] = 0x45
            return packet
        }

        var decoded: [Data] = []
        var batchCount = 0
        TunnelPacketBatchCodec.encode(packets) { batch in
            batchCount += 1
            XCTAssertLessThanOrEqual(batch.count, TunnelPacketBatchCodec.maxEncodedByteCount)
            var decodedInBatch = 0
            XCTAssertTrue(TunnelPacketBatchCodec.decode(batch) { packet, _ in
                decoded.append(packet)
                decodedInBatch += 1
            })
            XCTAssertLessThanOrEqual(decodedInBatch, TunnelPacketBatchCodec.maxPacketCount)
        }

        XCTAssertGreaterThan(batchCount, 1)
        XCTAssertEqual(decoded, packets)
    }

    func testPacketDecoderRejectsOversizedAndMalformedFrames() {
        let oversized = Data(count: TunnelPacketBatchCodec.maxEncodedByteCount + 1)
        XCTAssertFalse(TunnelPacketBatchCodec.decode(oversized) { _, _ in
            XCTFail("oversized frame emitted a packet")
        })

        let malformed = Data([0, 4, 0x45, 0x00])
        XCTAssertFalse(TunnelPacketBatchCodec.decode(malformed) { _, _ in
            XCTFail("malformed frame emitted a packet")
        })
    }

    func testStartupCleanupRunsUntilCommitted() {
        var cleanupCount = 0
        do {
            _ = TunnelStartupCleanup {
                cleanupCount += 1
            }
        }
        XCTAssertEqual(cleanupCount, 1)

        do {
            let cleanup = TunnelStartupCleanup {
                cleanupCount += 1
            }
            cleanup.cleanUpNow()
            XCTAssertEqual(cleanupCount, 2)
        }
        XCTAssertEqual(cleanupCount, 2)

        do {
            let cleanup = TunnelStartupCleanup {
                cleanupCount += 1
            }
            cleanup.commit()
        }
        XCTAssertEqual(cleanupCount, 2)
    }
}
