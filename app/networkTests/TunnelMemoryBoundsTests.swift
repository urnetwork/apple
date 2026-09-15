import XCTest

final class TunnelMemoryBoundsTests: XCTestCase {
    // The device target each platform hands SdkNewDeviceLocalWithMemoryTarget,
    // and the budget it hands SdkSetMemoryLimit: iOS 20 inside 32 MiB (jetsam),
    // macOS 128 inside 384 MiB.
    func testDeviceMemoryTargetPerPlatform() {
        XCTAssertEqual(TunnelDeviceMemoryTarget.iosByteCount, 20 * 1024 * 1024)
        XCTAssertEqual(TunnelDeviceMemoryTarget.macosByteCount, 128 * 1024 * 1024)
        XCTAssertEqual(TunnelDeviceMemoryTarget.iosProcessBudgetByteCount, 32 * 1024 * 1024)
        XCTAssertEqual(TunnelDeviceMemoryTarget.macosProcessBudgetByteCount, 384 * 1024 * 1024)
#if os(iOS)
        XCTAssertEqual(TunnelDeviceMemoryTarget.byteCount, 20 * 1024 * 1024)
        XCTAssertEqual(TunnelDeviceMemoryTarget.processBudgetByteCount, 32 * 1024 * 1024)
#else
        XCTAssertEqual(TunnelDeviceMemoryTarget.byteCount, 128 * 1024 * 1024)
        XCTAssertEqual(TunnelDeviceMemoryTarget.processBudgetByteCount, 384 * 1024 * 1024)
#endif
    }

    // The macOS pair satisfies both constraints on a target and its budget. iOS
    // is the documented exception (jetsam caps the budget at 32 MiB), so it is
    // pinned above by value and deliberately not asserted here.
    func testMacosMemoryTargetIsBackedAndCollectorSafe() {
        let target = TunnelDeviceMemoryTarget.macosByteCount
        let budget = TunnelDeviceMemoryTarget.macosProcessBudgetByteCount
        let targetParts = TunnelDeviceMemoryTarget.budgetRatioParts
            - TunnelDeviceMemoryTarget.poolRatioParts

        // backing: the target is at most 20/34 of the budget
        XCTAssertLessThanOrEqual(
            target * TunnelDeviceMemoryTarget.budgetRatioParts,
            budget * targetParts
        )
        // collector: the budget is at least three times the target
        XCTAssertGreaterThanOrEqual(
            budget,
            TunnelDeviceMemoryTarget.collectorBudgetMultiple * target
        )
    }

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

    func testConcurrentStartupCleanupHasExactlyOneOwner() {
        let lock = NSLock()
        var count = 0
        let cleanup = TunnelStartupCleanup {
            lock.lock()
            count += 1
            lock.unlock()
        }
        let group = DispatchGroup()
        for _ in 0..<24 {
            group.enter()
            DispatchQueue.global().async {
                cleanup.cleanUpNow()
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        lock.lock()
        let completed = count
        lock.unlock()
        XCTAssertEqual(completed, 1)
    }

    func testStartupCleanupRunsOutsideItsDisarmLock() {
        var cleanup: TunnelStartupCleanup?
        var count = 0
        cleanup = TunnelStartupCleanup {
            count += 1
            cleanup?.commit()
            cleanup?.cleanUpNow()
        }
        cleanup?.cleanUpNow()
        XCTAssertEqual(count, 1)
        cleanup = nil
        XCTAssertEqual(count, 1)
    }
}
