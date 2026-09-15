import Foundation

// The per-device memory target PacketTunnelProvider passes to
// SdkNewDeviceLocalWithMemoryTarget, and the process budget it passes to
// SdkSetMemoryLimit. The two are one decision: connect draws the H3 carrier
// windows from the device target (the stream window is three quarters of the
// carrier's eighth, so 3 * target / 32), while the device target itself has to
// be backed by the process budget.
//
// Two constraints bind the pair, and macOS satisfies both:
//
//   backing    the device targets plus the message pools must fit the process
//              budget, and the pools take 14 of 34 parts, so a target may be at
//              most 20/34 of the budget. 128 MiB <= 20/34 * 384 MiB = 225.9.
//   collector  SdkSetMemoryLimit is also the go soft limit, and live heap
//              amplifies about threefold at the runtime; a target too close to
//              its soft limit reproduces the measured mobile collection storm.
//              The budget is therefore at least three times the target:
//              384 MiB = 3 * 128 MiB.
//
// iOS is the documented exception to both, and is not ours to change here: the
// packet-tunnel extension is killed by jetsam at 50 MiB, so it holds a 20 MiB
// target inside a 32 MiB budget. macOS reports no packet-tunnel jetsam limit
// (and no job object or rlimit stands in for one), so it runs the desktop
// tiers.
//
// macOS has two of them. The base pair is the floor every Mac gets; a Mac with
// largeHostThresholdByteCount or more of physical memory gets the large pair,
// which doubles both numbers and so doubles the H3 stream window again. The
// tier is chosen from MEASURED host memory (hw.memsize), never from an
// assumption, and a Mac whose memory cannot be read takes the base pair: an
// unknown host is not a large host.
enum TunnelDeviceMemoryTarget {
    static let iosByteCount: Int64 = 20 * 1024 * 1024
    static let macosByteCount: Int64 = 128 * 1024 * 1024
    static let macosLargeHostByteCount: Int64 = 256 * 1024 * 1024

    static let iosProcessBudgetByteCount: Int64 = 32 * 1024 * 1024
    static let macosProcessBudgetByteCount: Int64 = 384 * 1024 * 1024
    static let macosLargeHostProcessBudgetByteCount: Int64 = 768 * 1024 * 1024

    static let largeHostThresholdByteCount: Int64 = 16 * 1024 * 1024 * 1024

    // The pools take 14 of 34 parts of the process budget, leaving 20 parts for
    // the device targets it backs.
    static let poolRatioParts: Int64 = 14
    static let budgetRatioParts: Int64 = 34

    // The go soft limit is the process budget, and live heap amplifies about
    // threefold; treat three as a floor rather than an estimate.
    static let collectorBudgetMultiple: Int64 = 3

    // One tier: a device target and the process budget that backs it, which are
    // only ever chosen together.
    struct Tier: Equatable {
        let deviceTargetByteCount: Int64
        let processBudgetByteCount: Int64

        // backing: the target is at most 20/34 of the budget
        var isBacked: Bool {
            deviceTargetByteCount * budgetRatioParts
                <= processBudgetByteCount * (budgetRatioParts - poolRatioParts)
        }

        // collector: the budget is at least three times the target
        var isCollectorSafe: Bool {
            collectorBudgetMultiple * deviceTargetByteCount <= processBudgetByteCount
        }
    }

    // The macOS tier for a host with `hostMemoryByteCount` bytes of physical
    // memory. nil or a nonpositive measurement takes the base tier.
    static func macosTier(hostMemoryByteCount: Int64?) -> Tier {
        guard let hostMemoryByteCount, largeHostThresholdByteCount <= hostMemoryByteCount else {
            return Tier(
                deviceTargetByteCount: macosByteCount,
                processBudgetByteCount: macosProcessBudgetByteCount
            )
        }
        return Tier(
            deviceTargetByteCount: macosLargeHostByteCount,
            processBudgetByteCount: macosLargeHostProcessBudgetByteCount
        )
    }

    static let iosTier = Tier(
        deviceTargetByteCount: iosByteCount,
        processBudgetByteCount: iosProcessBudgetByteCount
    )

    // Physical memory in bytes, or nil when it cannot be read. hw.memsize is
    // the machine's RAM; a packet-tunnel extension is not in a container that
    // could bound it below that.
    static func hostMemoryByteCount() -> Int64? {
        var byteCount: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname("hw.memsize", &byteCount, &size, nil, 0) == 0,
              size == MemoryLayout<UInt64>.size,
              0 < byteCount, byteCount <= UInt64(Int64.max) else {
            return nil
        }
        return Int64(byteCount)
    }

    // Resolved once per process. That is the point rather than an optimisation:
    // the budget is set when the provider is created and the target when the
    // session starts, and the two must come from the SAME tier.
    static let tier: Tier = {
#if os(iOS)
        return iosTier
#else
        return macosTier(hostMemoryByteCount: hostMemoryByteCount())
#endif
    }()

    static var byteCount: Int64 { tier.deviceTargetByteCount }

    static var processBudgetByteCount: Int64 { tier.processBudgetByteCount }
}

// Owns cleanup while PacketTunnelProvider is assembling a session. If setup
// returns early, deinit closes the partially-started SDK device. Once the
// provider has installed its full session close closure, commit transfers that
// responsibility to the provider. Lifecycle and deferred startup callers share
// only the short take/disarm lock; cleanup itself never runs under that lock.
final class TunnelStartupCleanup {
    private let lock = NSLock()
    private var cleanup: (() -> Void)?

    init(_ cleanup: @escaping () -> Void) {
        self.cleanup = cleanup
    }

    func commit() {
        lock.lock()
        let previous = cleanup
        cleanup = nil
        lock.unlock()
        withExtendedLifetime(previous) {}
    }

    func cleanUpNow() {
        lock.lock()
        let cleanup = cleanup
        self.cleanup = nil
        lock.unlock()
        cleanup?()
    }

    deinit {
        cleanUpNow()
    }
}

enum TunnelPacketBatchCodec {
    static let maxPacketCount = 64
    static let maxEncodedByteCount = 96 * 1024

    // Each emitted Data is a complete uint16-length-prefixed frame bounded by
    // both packet count and bytes. Invalid individual packets are skipped, as
    // they were by the prior bridge implementation.
    static func encode(_ packets: [Data], emit: (Data) -> Void) {
        var batch = Data()
        var batchPacketCount = 0

        for packet in packets {
            guard !packet.isEmpty, packet.count <= Int(UInt16.max) else {
                continue
            }

            let encodedByteCount = 2 + packet.count
            if batchPacketCount == maxPacketCount
                || (!batch.isEmpty && maxEncodedByteCount < batch.count + encodedByteCount) {
                emit(batch)
                batch = Data()
                batchPacketCount = 0
            }

            if batch.isEmpty {
                batch.reserveCapacity(min(maxEncodedByteCount, max(2048, encodedByteCount)))
            }
            var packetByteCount = UInt16(packet.count).bigEndian
            Swift.withUnsafeBytes(of: &packetByteCount) {
                batch.append(contentsOf: $0)
            }
            batch.append(packet)
            batchPacketCount += 1
        }

        if !batch.isEmpty {
            emit(batch)
        }
    }

    // Validates the whole frame before copying or emitting any packet, so a
    // corrupt suffix cannot cause a partial write to NEPacketTunnelFlow.
    @discardableResult
    static func decode(
        _ packetBatchBytes: Data,
        emit: (Data, UInt8) -> Void
    ) -> Bool {
        guard !packetBatchBytes.isEmpty,
              packetBatchBytes.count <= maxEncodedByteCount else {
            return false
        }

        return packetBatchBytes.withUnsafeBytes { rawBuffer -> Bool in
            guard let bytes = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return false
            }

            var offset = 0
            var packetCount = 0
            while offset < rawBuffer.count {
                guard packetCount < maxPacketCount,
                      2 <= rawBuffer.count - offset else {
                    return false
                }
                let packetByteCount = (Int(bytes[offset]) << 8) | Int(bytes[offset + 1])
                offset += 2
                guard 0 < packetByteCount,
                      packetByteCount <= rawBuffer.count - offset else {
                    return false
                }
                offset += packetByteCount
                packetCount += 1
            }

            offset = 0
            while offset < rawBuffer.count {
                let packetByteCount = (Int(bytes[offset]) << 8) | Int(bytes[offset + 1])
                offset += 2
                let ipVersion = bytes[offset] >> 4
                if ipVersion == 4 || ipVersion == 6 {
                    emit(Data(bytes: bytes + offset, count: packetByteCount), ipVersion)
                }
                offset += packetByteCount
            }
            return true
        }
    }
}
