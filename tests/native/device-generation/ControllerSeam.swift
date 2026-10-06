// Appended to the exact copied source so Swift private members remain private
// in production. No controller method body or dispatch operation is replaced.
extension SplitTunnelProxyController {
    func testPrepare(manager: NETransparentProxyManager, connectEnabled: Bool) {
        inputs.wantedApps = ["example.synthetic.excluded"]
        inputs.extensionState = .activated(willCompleteAfterReboot: false)
        inputs.connectEnabled = connectEnabled
        setManager(manager)
    }
    func testSetDevice(_ device: SdkDeviceRemote?) {
        setDevice(device)
    }
    var testConnectEnabled: Bool { inputs.connectEnabled }
    func testRefreshObservation() {
        setManager(manager)
    }
}
