import XCTest
@testable import URnetwork

// Invoke the actual constructor and startup gate, replacing only the scheduled
// operation. No SDK/API work, Keychain, or NetworkExtension access runs here.
@MainActor
final class DeviceManagerStartupInitializationTests: XCTestCase {
    func testProductionConstructorSchedulesInitializationExactlyOnce() {
        var scheduled = 0
        let manager = DeviceManager(
            startupMode: .production,
            scheduleStartupInitialization: { manager in
                scheduled += 1
                XCTAssertEqual(manager.startupMode, .production)
            }
        )
        XCTAssertEqual(scheduled, 1)
        XCTAssertEqual(manager.startupInitializationInvocationCount, 1)
        XCTAssertEqual(manager.vpnManagerInitializationInvocationCount, 0)
        XCTAssertNil(manager.networkSpace)
        XCTAssertNil(manager.vpnManager)
    }

    func testHardwareNoVPNConstructorSchedulesInitializationExactlyOnce() {
        var scheduled = 0
        let manager = DeviceManager(
            startupMode: .hardwareNoVPN,
            scheduleStartupInitialization: { manager in
                scheduled += 1
                XCTAssertEqual(manager.startupMode, .hardwareNoVPN)
            }
        )
        XCTAssertEqual(scheduled, 1)
        XCTAssertEqual(manager.startupInitializationInvocationCount, 1)
        XCTAssertFalse(manager.startupMode.allowsVPNProfileSystemAccess)
        XCTAssertNil(manager.networkSpace)
        XCTAssertNil(manager.vpnManager)
    }

    func testRejectedHardwareRequestCannotScheduleInitialization() {
        var scheduled = 0
        let manager = DeviceManager(
            startupMode: .rejectedHardwareTestRequest,
            scheduleStartupInitialization: { _ in scheduled += 1 }
        )
        XCTAssertEqual(scheduled, 0)
        XCTAssertEqual(manager.startupInitializationInvocationCount, 0)
        XCTAssertTrue(manager.deviceInitialized)
        XCTAssertNil(manager.networkSpace)
        XCTAssertNil(manager.vpnManager)
    }

    func testConstructorOnlyOptOutDoesNotScheduleProductionInitialization() {
        var scheduled = 0
        let manager = DeviceManager(
            startupMode: .production,
            automaticallyInitialize: false,
            scheduleStartupInitialization: { _ in scheduled += 1 }
        )
        XCTAssertEqual(scheduled, 0)
        XCTAssertEqual(manager.startupInitializationInvocationCount, 0)
        XCTAssertEqual(manager.startupMode, .production)
        XCTAssertNil(manager.networkSpace)
        XCTAssertNil(manager.vpnManager)
    }

    func testMemoryOptOutDoesNotChangeLaterNormalHardwareStartup() {
        var scheduled = 0
        let inert = DeviceManager(
            startupMode: .hardwareNoVPN,
            automaticallyInitialize: false,
            scheduleStartupInitialization: { _ in scheduled += 1 }
        )
        let normal = DeviceManager(
            startupMode: .hardwareNoVPN,
            scheduleStartupInitialization: { _ in scheduled += 1 }
        )
        XCTAssertEqual(inert.startupInitializationInvocationCount, 0)
        XCTAssertEqual(normal.startupInitializationInvocationCount, 1)
        XCTAssertEqual(scheduled, 1)
    }

    func testDefaultConstructorModeStillUsesExistingLaunchContract() {
        var scheduled = 0
        let manager = DeviceManager(
            scheduleStartupInitialization: { _ in scheduled += 1 }
        )
        let expectedMode = HardwareNoVPNLaunchContract.current
        XCTAssertEqual(manager.startupMode, expectedMode)
        XCTAssertEqual(scheduled, expectedMode.allowsStartupInitialization ? 1 : 0)
        XCTAssertEqual(manager.startupInitializationInvocationCount, scheduled)
    }
}
