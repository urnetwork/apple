import Darwin
import XCTest

final class ExtensionMemoryFootprintTests: XCTestCase {
    private let mib: Int64 = 1024 * 1024

    private func info(
        current: UInt64 = 20 * 1024 * 1024,
        peak: Int64 = 31 * 1024 * 1024,
        remaining: UInt64 = 30 * 1024 * 1024
    ) -> task_vm_info_data_t {
        var value = task_vm_info_data_t()
        value.phys_footprint = current
        value.ledger_phys_footprint_peak = peak
        value.limit_bytes_remaining = remaining
        return value
    }

    private func decode(
        _ value: task_vm_info_data_t,
        count: mach_msg_type_number_t = ExtensionMemoryFootprint.capacity,
        result: kern_return_t = KERN_SUCCESS
    ) -> ExtensionMemoryFootprint {
        ExtensionMemoryFootprint.decode(result: result, count: count, info: value)
    }

    func testOneReadRetainsKernelPeakWithoutReplacingCurrentSDKSample() {
        var calls = 0
        let observation = ExtensionMemoryFootprint.capture { value, count in
            calls += 1
            XCTAssertEqual(count, ExtensionMemoryFootprint.capacity)
            value = self.info(peak: 49 * self.mib)
            return KERN_SUCCESS
        }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(observation.status, .complete)
        XCTAssertEqual(observation.currentByteCount, 20 * mib)
        XCTAssertEqual(observation.kernelPeakByteCount, 49 * mib)
        XCTAssertEqual(observation.limitRemainingByteCount, 30 * mib)
        var sdkCalls = 0
        let line = observation.logLine(event: "periodic") { event, current in
            sdkCalls += 1
            XCTAssertEqual(event, "periodic")
            XCTAssertEqual(current, 20 * self.mib, "kernel peak must not arm pressure as current use")
            return "[memory] event=periodic phys_footprint_bytes=\(current)"
        }
        XCTAssertEqual(sdkCalls, 1)
        XCTAssertTrue(line.contains("phys_kernel_peak_bytes=51380224"))
        XCTAssertTrue(line.contains("phys_snapshot_status=complete"))
    }

    func testReturnedCountIndependentlyGatesRevisionFields() {
        XCTAssertLessThan(ExtensionMemoryFootprint.currentMinimumCount, ExtensionMemoryFootprint.peakMinimumCount)
        XCTAssertLessThan(ExtensionMemoryFootprint.peakMinimumCount, ExtensionMemoryFootprint.remainingMinimumCount)
        XCTAssertLessThanOrEqual(ExtensionMemoryFootprint.remainingMinimumCount, ExtensionMemoryFootprint.capacity)

        let short = decode(info(), count: ExtensionMemoryFootprint.currentMinimumCount - 1)
        XCTAssertEqual(short.status, .shortCurrent)
        XCTAssertNil(short.currentByteCount)
        XCTAssertNil(short.kernelPeakByteCount)
        XCTAssertNil(short.limitRemainingByteCount)

        let current = decode(info(), count: ExtensionMemoryFootprint.currentMinimumCount)
        XCTAssertEqual(current.status, .partial)
        XCTAssertEqual(current.currentByteCount, 20 * mib)
        XCTAssertNil(current.kernelPeakByteCount)
        XCTAssertNil(current.limitRemainingByteCount)
        XCTAssertNil(decode(info(), count: ExtensionMemoryFootprint.peakMinimumCount - 1).kernelPeakByteCount)

        let peak = decode(info(), count: ExtensionMemoryFootprint.peakMinimumCount)
        XCTAssertEqual(peak.status, .partial)
        XCTAssertEqual(peak.kernelPeakByteCount, 31 * mib)
        XCTAssertNil(peak.limitRemainingByteCount)
        XCTAssertNil(decode(info(), count: ExtensionMemoryFootprint.remainingMinimumCount - 1).limitRemainingByteCount)
        XCTAssertEqual(decode(info(), count: ExtensionMemoryFootprint.remainingMinimumCount).status, .complete)
    }

    func testReadFailureRejectsApparentlyPopulatedFieldsAndNeverRecordsZero() {
        for result in [KERN_FAILURE, KERN_INVALID_ARGUMENT, KERN_PROTECTION_FAILURE] {
            let observation = decode(info(), result: result)
            XCTAssertEqual(observation.status, .taskInfoFailed)
            XCTAssertNil(observation.currentByteCount)
            XCTAssertNil(observation.kernelPeakByteCount)
            XCTAssertNil(observation.limitRemainingByteCount)
            var called = false
            let line = observation.logLine(event: "periodic") { _, _ in
                called = true
                return "must-not-be-called"
            }
            XCTAssertFalse(called)
            XCTAssertTrue(line.contains("phys_current_available=false"))
            XCTAssertTrue(line.contains("phys_kernel_peak_bytes=unavailable"))
            XCTAssertTrue(line.contains("phys_limit_remaining_bytes=unavailable"))
            XCTAssertFalse(line.contains("phys_footprint_bytes=0"))
            XCTAssertFalse(line.contains("go_total_bytes="))
        }
    }

    func testInvalidAndShortCountsDoNotReadUnreportedStorage() {
        for count in [0, ExtensionMemoryFootprint.currentMinimumCount - 1] {
            XCTAssertEqual(decode(info(), count: count).status, .shortCurrent)
        }
        for count in [ExtensionMemoryFootprint.capacity + 1, mach_msg_type_number_t.max] {
            let observation = decode(info(), count: count)
            XCTAssertEqual(observation.status, .invalidCount)
            XCTAssertNil(observation.currentByteCount)
            XCTAssertNil(observation.kernelPeakByteCount)
            XCTAssertNil(observation.limitRemainingByteCount)
        }
    }

    func testInvalidValuesAreUnavailableButActualZeroRemainingIsRetained() {
        for current: UInt64 in [0, UInt64.max] {
            let observation = decode(info(current: current))
            XCTAssertEqual(observation.status, .invalidCurrent)
            XCTAssertNil(observation.currentByteCount)
            XCTAssertNil(observation.kernelPeakByteCount)
        }
        for peak in [Int64(-1), 0, 20 * mib - 1] {
            let observation = decode(info(peak: peak))
            XCTAssertEqual(observation.status, .partial)
            XCTAssertEqual(observation.currentByteCount, 20 * mib)
            XCTAssertNil(observation.kernelPeakByteCount)
        }
        XCTAssertNil(decode(info(remaining: .max)).limitRemainingByteCount)
        let exhausted = decode(info(remaining: 0))
        XCTAssertEqual(exhausted.status, .complete)
        XCTAssertEqual(exhausted.limitRemainingByteCount, 0)
        let line = exhausted.logLine(event: "periodic") { _, _ in "[memory]" }
        XCTAssertTrue(line.contains("phys_limit_remaining_available=true phys_limit_remaining_bytes=0"))
    }

    func testKernelPeakCrossingIsRetainedEvenWhenCurrentSamplesMissIt() {
        let before = decode(info(peak: 20 * mib))
        let after = decode(info(peak: 50 * mib + 1))
        XCTAssertEqual(before.currentByteCount, after.currentByteCount)
        XCTAssertEqual(after.kernelPeakByteCount, 52_428_801)
        XCTAssertGreaterThan(after.kernelPeakByteCount!, before.kernelPeakByteCount!)
        // Observation only: never clamp to the proposed boundary or the Go cap.
        XCTAssertTrue(after.logLine(event: "periodic") { _, _ in "[memory]" }
            .contains("phys_kernel_peak_bytes=52428801"))
    }

    func testUnavailableNewObservationDoesNotInheritPreviousPeak() {
        XCTAssertEqual(decode(info()).kernelPeakByteCount, 31 * mib)
        let failed = decode(info(), result: KERN_FAILURE)
        XCTAssertNil(failed.kernelPeakByteCount)
        let oldRevision = decode(info(), count: ExtensionMemoryFootprint.currentMinimumCount)
        XCTAssertNil(oldRevision.kernelPeakByteCount)
        XCTAssertTrue(oldRevision.logLine(event: "periodic") { _, _ in "[memory]" }
            .contains("phys_kernel_peak_available=false phys_kernel_peak_bytes=unavailable"))
    }
}
