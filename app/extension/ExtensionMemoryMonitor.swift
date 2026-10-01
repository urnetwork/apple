import Darwin
import Foundation
import OSLog
import URnetworkExtensionSdk

/// Samples the two memory gauges that matter for the packet tunnel:
/// Go's soft-limit accounting and the kernel's physical-footprint ledger.
/// OSLog also retains the kernel lifetime peak and available-memory result
/// from that same task_info call, with explicit field availability. The SDK's
/// existing diagnostic log remains the paired current-footprint/Go snapshot.
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
        let footprint = ExtensionMemoryFootprint.capture()
        let line = footprint.logLine(event: event) { event, currentByteCount in
            SdkRecordExtensionMemorySample(event, currentByteCount)
        }
        logger.info("\(line, privacy: .public)")
    }
}
