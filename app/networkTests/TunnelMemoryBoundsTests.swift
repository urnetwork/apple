import XCTest

final class TunnelMemoryBoundsTests: XCTestCase {
    // The device target each platform hands SdkNewDeviceLocalWithMemoryTarget,
    // and the budget it hands SdkSetMemoryLimit: iOS 20 inside 32 MiB (jetsam),
    // macOS 128 inside 384, or 256 inside 768 on a host with 32 GiB or more.
    func testDeviceMemoryTargetPerPlatform() {
        XCTAssertEqual(TunnelDeviceMemoryTarget.iosByteCount, 20 * 1024 * 1024)
        XCTAssertEqual(TunnelDeviceMemoryTarget.macosByteCount, 128 * 1024 * 1024)
        XCTAssertEqual(TunnelDeviceMemoryTarget.macosLargeHostByteCount, 256 * 1024 * 1024)
        XCTAssertEqual(TunnelDeviceMemoryTarget.iosProcessBudgetByteCount, 32 * 1024 * 1024)
        XCTAssertEqual(TunnelDeviceMemoryTarget.macosProcessBudgetByteCount, 384 * 1024 * 1024)
        XCTAssertEqual(
            TunnelDeviceMemoryTarget.macosLargeHostProcessBudgetByteCount,
            768 * 1024 * 1024
        )
        XCTAssertEqual(
            TunnelDeviceMemoryTarget.largeHostThresholdByteCount,
            32 * 1024 * 1024 * 1024
        )
#if os(iOS)
        XCTAssertEqual(TunnelDeviceMemoryTarget.byteCount, 20 * 1024 * 1024)
        XCTAssertEqual(TunnelDeviceMemoryTarget.processBudgetByteCount, 32 * 1024 * 1024)
#else
        // Whatever this Mac measures, the resolved pair is one of the two tiers
        // and never a mix of them.
        XCTAssertEqual(
            TunnelDeviceMemoryTarget.tier,
            TunnelDeviceMemoryTarget.macosTier(
                hostMemoryByteCount: TunnelDeviceMemoryTarget.hostMemoryByteCount()
            )
        )
#endif
    }

    // The gate over the measurement, including the failure case: an unknown
    // host takes the base tier, because an unknown host is not a large host.
    func testMacosTierIsChosenFromMeasuredHostMemory() {
        let gib: Int64 = 1024 * 1024 * 1024
        let base = TunnelDeviceMemoryTarget.macosByteCount
        let large = TunnelDeviceMemoryTarget.macosLargeHostByteCount
        let rows: [(Int64?, Int64)] = [
            (nil, base),          // sysctl failed
            (0, base),            // nothing measured
            (-1, base),           // a nonsense measurement
            (8 * gib, base),      // an ordinary laptop
            (16 * gib, base),     // a 16 GiB laptop: the bar is deliberately above it
            (32 * gib - 1, base), // one byte under the bar
            (32 * gib, large),
            (64 * gib, large),
        ]
        for (host, expected) in rows {
            XCTAssertEqual(
                TunnelDeviceMemoryTarget.macosTier(hostMemoryByteCount: host).deviceTargetByteCount,
                expected,
                "host \(String(describing: host))"
            )
        }
        // The budget always moves with the target it backs.
        XCTAssertEqual(
            TunnelDeviceMemoryTarget.macosTier(hostMemoryByteCount: 8 * gib).processBudgetByteCount,
            TunnelDeviceMemoryTarget.macosProcessBudgetByteCount
        )
        XCTAssertEqual(
            TunnelDeviceMemoryTarget.macosTier(hostMemoryByteCount: 64 * gib).processBudgetByteCount,
            TunnelDeviceMemoryTarget.macosLargeHostProcessBudgetByteCount
        )
    }

    // Both constraints on BOTH macOS tiers. iOS is the documented exception
    // (jetsam caps the budget at 32 MiB), so it is pinned above by value and
    // deliberately not asserted here.
    func testEveryMacosTierIsBackedAndCollectorSafe() {
        let gib: Int64 = 1024 * 1024 * 1024
        for host: Int64? in [nil, 8 * gib, 32 * gib, 128 * gib] {
            let tier = TunnelDeviceMemoryTarget.macosTier(hostMemoryByteCount: host)
            XCTAssertTrue(tier.isBacked, "host \(String(describing: host)) target is not backed")
            XCTAssertTrue(
                tier.isCollectorSafe,
                "host \(String(describing: host)) budget is too close to its target"
            )
        }
    }

    // The probe on the machine running the test: either a real measurement or
    // nil, never a value that would read as a large host by accident.
    func testHostMemoryProbeReadsThisMachineOrNothing() {
        guard let byteCount = TunnelDeviceMemoryTarget.hostMemoryByteCount() else {
            return
        }
        XCTAssertGreaterThan(byteCount, 512 * 1024 * 1024)
        XCTAssertLessThan(byteCount, 64 * 1024 * 1024 * 1024 * 1024)
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
