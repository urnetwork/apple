// Occupying the real main queue is the delivery barrier. A serial fake SDK
// queue invokes the actual listener; its real main.async cannot run until
// the replacement below finishes. The assertion is enqueued after delivery.
import Foundation
import NetworkExtension
import URnetworkSdk

private let sdkQueue = DispatchQueue(label: "example.synthetic.sdk")
private var failures: [String] = []

private func expect(_ value: @autoclosure () -> Bool, _ message: String) {
    if !value() {
        failures.append(message)
    }
}

private func finish(_ scenario: String) -> Never {
    if failures.isEmpty {
        print("PASS \(scenario)")
        exit(0)
    }
    for message in failures {
        print("FAIL \(scenario): \(message)")
    }
    exit(1)
}

private func makeManager(running: Bool) -> NETransparentProxyManager {
    let manager = NETransparentProxyManager()
    let configuration = SplitTunnelProxyConfiguration(excludedApps: ["example.synthetic.excluded"])
    let tunnelProtocol = NETunnelProviderProtocol()
    tunnelProtocol.providerBundleIdentifier = TunnelProviderIdentity.splitTunnelBundleIdentifier
    tunnelProtocol.providerConfiguration = configuration.providerConfiguration
    manager.protocolConfiguration = tunnelProtocol
    manager.isEnabled = true
    manager.connection.status = running ? .connected : .disconnected
    return manager
}

private func expectNoPreferences(_ manager: NETransparentProxyManager) {
    expect(NETransparentProxyManager.loadCount == 0, "unexpected preference load")
    expect(manager.saveCount == 0, "unexpected preference save")
    expect(manager.reloadCount == 0, "unexpected preference reload")
    expect(manager.removeCount == 0, "unexpected preference removal")
    expect(manager.connection.messageCount == 0, "unexpected provider message")
}

// Both values from the replacement's live subscription remain actionable.
private func verifyLiveReplacement(_ controller: SplitTunnelProxyController,
                                   _ manager: NETransparentProxyManager,
                                   _ device: SdkDeviceRemote,
                                   _ scenario: String) {
    let startCount = manager.connection.startCount
    let stopCount = manager.connection.stopCount
    sdkQueue.sync { device.emit(true) }
    DispatchQueue.main.async {
        expect(controller.testConnectEnabled, "live replacement connect was ignored")
        expect(manager.connection.startCount == startCount + 1, "live replacement did not start exactly once")
        controller.testRefreshObservation()
        sdkQueue.sync { device.emit(false) }
        DispatchQueue.main.async {
            expect(!controller.testConnectEnabled, "live replacement disconnect was ignored")
            expect(manager.connection.stopCount == stopCount + 1, "live replacement did not stop exactly once")
            expectNoPreferences(manager)
            finish(scenario)
        }
    }
}

private func run(_ scenario: String) {
    dispatchPrecondition(condition: .onQueue(.main))
    if scenario == "deinit" {
        let manager = makeManager(running: false)
        let device = SdkDeviceRemote(connectEnabled: false)
        var controller: SplitTunnelProxyController? = SplitTunnelProxyController()
        controller!.testPrepare(manager: manager, connectEnabled: false)
        controller!.testSetDevice(device)
        weak var weakController = controller
        sdkQueue.sync { device.emit(true) }
        controller = nil
        expect(weakController == nil, "queued callback retained controller through teardown")
        expect(device.subscriptions[0].isClosed, "teardown did not close subscription")
        DispatchQueue.main.async {
            expect(manager.connection.startCount == 0, "callback started proxy after teardown")
            expect(manager.connection.stopCount == 0, "callback stopped proxy after teardown")
            expectNoPreferences(manager)
            finish(scenario)
        }
        return
    }

    let startsRunning = scenario == "retired-disconnect-replacement"
    let manager = makeManager(running: startsRunning)
    let controller = SplitTunnelProxyController()
    controller.testPrepare(manager: manager, connectEnabled: startsRunning)
    let firstDevice = SdkDeviceRemote(connectEnabled: startsRunning)
    controller.testSetDevice(firstDevice)
    let firstSubscription = firstDevice.subscriptions[0]

    if scenario == "live" {
        verifyLiveReplacement(controller, manager, firstDevice, scenario)
        return
    }

    let replacement = SdkDeviceRemote(connectEnabled: startsRunning)
    if scenario != "closed-late-delivery" {
        sdkQueue.sync { firstDevice.emit(!startsRunning) }
    }
    // At this point the old callback is definitely queued on main, which
    // is still executing this block. Replacement is completed before yield.
    switch scenario {
    case "retired-connect-replacement", "retired-disconnect-replacement":
        controller.testSetDevice(replacement)
    case "detach":
        controller.testSetDevice(nil)
    case "same-device":
        firstDevice.connectEnabled = false
        controller.testSetDevice(firstDevice)
    case "aba":
        controller.testSetDevice(replacement)
        firstDevice.connectEnabled = false
        controller.testSetDevice(firstDevice)
        expect(replacement.subscriptions[0].isClosed, "intermediate subscription stayed open")
    case "closed-late-delivery":
        controller.testSetDevice(replacement)
        sdkQueue.sync { firstSubscription.deliverCaptured(true) }
    default:
        fatalError("unknown scenario \(scenario)")
    }
    expect(firstSubscription.isClosed, "retired subscription was not closed")
    expect(firstSubscription.closeCount == 1, "retired subscription close was duplicated")
    expect(controller.testConnectEnabled == startsRunning, "replacement initial value was not read")
    DispatchQueue.main.async {
        expect(controller.testConnectEnabled == startsRunning,
               "retired callback overwrote current input: expected=\(startsRunning) actual=\(controller.testConnectEnabled)")
        expect(manager.connection.startCount == 0,
               "retired callback started proxy: starts=\(manager.connection.startCount)")
        expect(manager.connection.stopCount == 0,
               "retired callback stopped proxy: stops=\(manager.connection.stopCount)")
        expectNoPreferences(manager)
        if scenario == "retired-connect-replacement" {
            verifyLiveReplacement(controller, manager, replacement, scenario)
        } else if scenario == "same-device" || scenario == "aba" {
            verifyLiveReplacement(controller, manager, firstDevice, scenario)
        } else {
            finish(scenario)
        }
    }
}

@main
enum ControllerHarness {
    static func main() {
        let scenario = CommandLine.arguments[1]
        DispatchQueue.main.async { run(scenario) }
        dispatchMain()
    }
}
