//
//  ExtenderProvideSettingTests.swift
//  networkTests
//

import Foundation
import Testing
import URnetworkSdk
@testable import URnetwork

// Work is held explicitly, as DeviceAuthCallbackOwnershipTests holds it: the
// lock protects only the queue, and no callback runs while it is held.
private final class ExtenderProvideHeldDispatcher: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [DeviceAuthCallbackWork] = []

    func enqueue(_ work: @escaping DeviceAuthCallbackWork) {
        lock.lock()
        pending.append(work)
        lock.unlock()
    }

    @MainActor @discardableResult
    func deliver() -> Int {
        lock.lock()
        let batch = pending
        pending.removeAll()
        lock.unlock()
        for work in batch { work() }
        return batch.count
    }
}

// The device side of the seam: what the device reports, the settings it holds
// (the provider extender and the lag.dev measurements), every read of them and
// every write that reaches them. Retaining the callback after close models a
// status the sdk admitted before the listener was removed.
private final class ExtenderProvideTestingSource: ExtenderProvideSource {
    private(set) var status: ExtenderProvideStatusModel
    private(set) var setting: Bool
    private(set) var writes: [Bool] = []
    private(set) var closes = 0
    private(set) var settingReads = 0
    private(set) var measurements: Bool
    private(set) var measurementsWrites: [Bool] = []
    private(set) var measurementsReads = 0
    private var callback: (@Sendable (ExtenderProvideStatusModel) -> Void)?

    init(status: ExtenderProvideStatusModel, setting: Bool, measurements: Bool = true) {
        self.status = status
        self.setting = setting
        self.measurements = measurements
    }

    func readExtenderProvideStatus() -> ExtenderProvideStatusModel { status }

    func readProvideExtender() -> Bool {
        settingReads += 1
        return setting
    }

    func writeProvideExtender(_ provideExtender: Bool) {
        writes.append(provideExtender)
        setting = provideExtender
    }

    func readMeasurementsEnabled() -> Bool {
        measurementsReads += 1
        return measurements
    }

    func writeMeasurementsEnabled(_ measurementsEnabled: Bool) {
        measurementsWrites.append(measurementsEnabled)
        measurements = measurementsEnabled
    }

    func observeExtenderProvideStatus(
        _ callback: @escaping @Sendable (ExtenderProvideStatusModel) -> Void
    ) -> () -> Void {
        self.callback = callback
        return { [weak self] in self?.closes += 1 }
    }

    // the device changes and the listener fires, as the sdk pushes it
    func push(_ status: ExtenderProvideStatusModel, setting: Bool, measurements: Bool? = nil) {
        self.status = status
        self.setting = setting
        if let measurements {
            self.measurements = measurements
        }
        callback?(status)
    }
}

/**
 * The Extender switch against the device (EXTENDER.md N1, N6, N7): the toggle
 * writes the setting through the device at once, the setting is neither
 * written nor read while the row is hidden, a pushed status replaces the guess
 * and moves the switch without writing it back, a status queued from a
 * replaced device is dropped, and the reset writes nothing.
 */
@MainActor
struct ExtenderProvideSettingTests {

    private static let active = ExtenderProvideStatusModel(
        supported: true,
        state: SdkExtenderProvideStateActive,
        activatedV4: true,
        enabled: true
    )
    private static let off = ExtenderProvideStatusModel(
        supported: true,
        state: SdkExtenderProvideStateOff
    )

    private let dispatcher: ExtenderProvideHeldDispatcher
    private let manager: DeviceManager

    init() {
        let dispatcher = ExtenderProvideHeldDispatcher()
        self.dispatcher = dispatcher
        manager = DeviceManager(
            startupMode: .production,
            automaticallyInitialize: false,
            extenderProvideCallbackDispatch: { dispatcher.enqueue($0) }
        )
    }

    @Test func theToggleWritesTheSettingThroughTheDevice() {
        let source = ExtenderProvideTestingSource(status: Self.active, setting: true)
        manager.setupExtenderProvide(source: source)
        #expect(manager.provideExtender)
        // the seed read is not written back
        #expect(source.writes.isEmpty)

        manager.provideExtender = false

        #expect(source.writes == [false])
        // repainted at once, before the listener answers
        #expect(manager.extenderProvideDisplay == ExtenderProvideDisplay.guess(on: false, providing: false))
    }

    // N1, N7: while the row is hidden the setting is neither written nor read
    @Test func nothingIsWrittenWhileTheRoleIsUnsupported() {
        let source = ExtenderProvideTestingSource(status: .unsupported, setting: true)
        manager.setupExtenderProvide(source: source)

        manager.provideExtender = false
        manager.provideExtender = true

        #expect(source.writes.isEmpty)
        #expect(source.settingReads == 0)
        #expect(manager.extenderProvideGuess == nil)
        #expect(!manager.extenderProvideDisplay.visible)
    }

    // N7: the setting is read beside a status only while that status reports
    // the role supported, at the seed and for every pushed status; the switch
    // keeps its value while it is not read
    @Test func anUnsupportedStatusReadsNoSetting() {
        let source = ExtenderProvideTestingSource(status: .unsupported, setting: false)
        manager.setupExtenderProvide(source: source)
        #expect(source.settingReads == 0)
        #expect(manager.provideExtender)

        source.push(.unsupported, setting: false)
        #expect(dispatcher.deliver() == 1)
        #expect(source.settingReads == 0)
        #expect(manager.provideExtender)

        source.push(Self.active, setting: false)
        #expect(dispatcher.deliver() == 1)
        #expect(source.settingReads == 1)
        #expect(!manager.provideExtender)

        source.push(.unsupported, setting: true)
        #expect(dispatcher.deliver() == 1)
        #expect(source.settingReads == 1)
        #expect(!manager.provideExtender)
        #expect(!manager.extenderProvideDisplay.visible)
        #expect(source.writes.isEmpty)
    }

    @Test func aPushedStatusReplacesTheGuessAndIsNotWrittenBack() {
        let source = ExtenderProvideTestingSource(status: Self.active, setting: true)
        manager.setupExtenderProvide(source: source)
        manager.provideExtender = false
        #expect(manager.extenderProvideGuess != nil)

        source.push(Self.off, setting: false)
        #expect(dispatcher.deliver() == 1)
        #expect(manager.extenderProvideGuess == nil)
        #expect(manager.extenderProvideStatus == Self.off)
        #expect(!manager.provideExtender)

        // another writer turns it back on: the switch follows the setting read
        // beside the status, and nothing is written
        source.push(Self.active, setting: true)
        #expect(dispatcher.deliver() == 1)
        #expect(manager.provideExtender)
        #expect(manager.extenderProvideStatus == Self.active)
        #expect(source.writes == [false])
    }

    @Test func aStatusQueuedFromAReplacedDeviceIsDropped() {
        let old = ExtenderProvideTestingSource(status: Self.active, setting: true)
        manager.setupExtenderProvide(source: old)
        old.push(Self.off, setting: false)

        let replacement = ExtenderProvideTestingSource(
            status: ExtenderProvideStatusModel(supported: true, state: SdkExtenderProvideStateNotProviding),
            setting: true
        )
        manager.setupExtenderProvide(source: replacement)
        #expect(old.closes == 1)
        // the old status runs and changes nothing
        #expect(dispatcher.deliver() == 1)

        #expect(manager.extenderProvideStatus.state == SdkExtenderProvideStateNotProviding)
        #expect(manager.provideExtender)
        #expect(old.writes.isEmpty)
        #expect(replacement.writes.isEmpty)
    }

    // N7: the status and the setting reset with the device, without a write,
    // and a toggle after the reset reaches nothing
    @Test func theResetHidesTheRowWithoutWriting() {
        let source = ExtenderProvideTestingSource(status: Self.active, setting: false)
        manager.setupExtenderProvide(source: source)
        #expect(!manager.provideExtender)
        let readsBeforeReset = source.settingReads

        manager.resetExtenderProvide()

        #expect(source.closes == 1)
        #expect(source.settingReads == readsBeforeReset)
        #expect(manager.extenderProvideStatus == .unsupported)
        #expect(manager.provideExtender)
        #expect(!manager.extenderProvideDisplay.visible)
        manager.provideExtender = false
        #expect(source.writes.isEmpty)
    }

    // lag.dev/PLAN.md C4: the speed tests switch goes through the device at
    // once, as the Extender switch does, and its seed read is not written back
    @Test func theSpeedTestsToggleWritesTheSettingThroughTheDevice() {
        let source = ExtenderProvideTestingSource(status: Self.active, setting: true, measurements: true)
        manager.setupExtenderProvide(source: source)
        #expect(manager.measurementsEnabled)
        #expect(source.measurementsReads == 1)
        #expect(source.measurementsWrites.isEmpty)

        manager.measurementsEnabled = false

        #expect(source.measurementsWrites == [false])
        // the Extender setting is untouched
        #expect(source.writes.isEmpty)
    }

    @Test func theSpeedTestsSettingIsNeitherReadNorWrittenWhileTheRoleIsUnsupported() {
        let source = ExtenderProvideTestingSource(status: .unsupported, setting: true, measurements: false)
        manager.setupExtenderProvide(source: source)
        #expect(source.measurementsReads == 0)
        #expect(manager.measurementsEnabled)

        manager.measurementsEnabled = false
        manager.measurementsEnabled = true

        #expect(source.measurementsWrites.isEmpty)
        #expect(source.measurementsReads == 0)
    }

    // another writer, such as connectctl on the same device, turns it off: the
    // switch follows the setting read beside the next status, and nothing is
    // written back
    @Test func aPushedStatusMovesTheSpeedTestsSwitchWithoutWritingIt() {
        let source = ExtenderProvideTestingSource(status: Self.active, setting: true, measurements: true)
        manager.setupExtenderProvide(source: source)

        source.push(Self.active, setting: true, measurements: false)
        #expect(dispatcher.deliver() == 1)

        #expect(!manager.measurementsEnabled)
        #expect(source.measurementsWrites.isEmpty)
    }

    @Test func theResetTurnsTheSpeedTestsSwitchBackOnWithoutWriting() {
        let source = ExtenderProvideTestingSource(status: Self.active, setting: true, measurements: false)
        manager.setupExtenderProvide(source: source)
        #expect(!manager.measurementsEnabled)

        manager.resetExtenderProvide()

        #expect(manager.measurementsEnabled)
        #expect(source.measurementsWrites.isEmpty)
        manager.measurementsEnabled = false
        #expect(source.measurementsWrites.isEmpty)
    }
}
