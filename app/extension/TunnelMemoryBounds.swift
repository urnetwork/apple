import Foundation

// Owns cleanup while PacketTunnelProvider is assembling a session. If setup
// returns early, deinit closes the partially-started SDK device. Once the
// provider has installed its full session close closure, commit transfers that
// responsibility to the provider.
final class TunnelStartupCleanup {
    private var cleanup: (() -> Void)?

    init(_ cleanup: @escaping () -> Void) {
        self.cleanup = cleanup
    }

    func commit() {
        cleanup = nil
    }

    func cleanUpNow() {
        let cleanup = cleanup
        self.cleanup = nil
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
