import Darwin
import Foundation
import OSLog
import URnetworkExtensionSdk

/// Samples the two memory gauges that matter for the packet tunnel:
/// Go's soft-limit accounting and the kernel's physical-footprint ledger.
/// A periodic, parseable log survives app/extension process separation and is
/// available in a device log or sysdiagnose after a jetsam event.
final class ExtensionMemoryMonitor {
    private let logger: Logger
    private let queue = DispatchQueue(label: "network.ur.extension.memory")
    private var timer: DispatchSourceTimer?

    init(logger: Logger) {
        self.logger = logger
    }

    func start() {
        queue.sync {
            guard timer == nil else {
                return
            }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(
                deadline: .now() + .seconds(5),
                repeating: .seconds(5),
                leeway: .milliseconds(500)
            )
            timer.setEventHandler { [weak self] in
                self?.sampleOnQueue(event: "periodic")
            }
            self.timer = timer
            timer.activate()
        }
        sample(event: "initialized")
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
        }
    }

    func sample(event: String) {
        queue.sync {
            sampleOnQueue(event: event)
        }
    }

    private func sampleOnQueue(event: String) {
        let physicalFootprintByteCount = Self.physicalFootprintByteCount()
        let line = SdkRecordExtensionMemorySample(
            event,
            Int64(clamping: physicalFootprintByteCount)
        )
        logger.info("\(line, privacy: .public)")
    }

    private static func physicalFootprintByteCount() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.stride /
                MemoryLayout<natural_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(
                to: integer_t.self,
                capacity: Int(count)
            ) { rebound in
                task_info(
                    mach_task_self_,
                    task_flavor_t(TASK_VM_INFO),
                    rebound,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else {
            return 0
        }
        return info.phys_footprint
    }
}
