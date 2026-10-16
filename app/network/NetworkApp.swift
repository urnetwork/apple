//
//  NetworkApp.swift
//  network
//
//  Created by brien on 11/18/24.
//

import SwiftUI
import URnetworkSdk
import GoogleSignIn

enum PresentationLifecycleTransition: Equatable {
    case resume
    case suspend
}

struct PresentationLifecycleState {
    private(set) var isActive = false

    static func shouldBeActive(sceneActive: Bool, presentationVisible: Bool) -> Bool {
        return sceneActive && presentationVisible
    }

    mutating func update(isActive nextIsActive: Bool) -> PresentationLifecycleTransition? {
        guard isActive != nextIsActive else {
            return nil
        }
        isActive = nextIsActive
        return nextIsActive ? .resume : .suspend
    }

    mutating func update(
        sceneActive: Bool,
        presentationVisible: Bool
    ) -> PresentationLifecycleTransition? {
        return update(
            isActive: Self.shouldBeActive(
                sceneActive: sceneActive,
                presentationVisible: presentationVisible
            )
        )
    }
}

struct PresentationWorkState {
    static func shouldRun(
        presentationActive: Bool,
        workReady: Bool = true
    ) -> Bool {
        return presentationActive && workReady
    }
}

/**
 * What the connect view model does on a device change or a presentation
 * transition. No device (signed out, or the device went away) is a reset,
 * whatever the window state: suspended instead, the signed out account's
 * pending status, waiting start, balance recovery and notice outlived it
 * until the next resume, and the start could still connect. With a device,
 * a hidden presentation suspends, and a shown one sets up unless it already
 * presents that device.
 */
enum ConnectViewModelUpdate: Equatable {
    case reset
    case suspend
    case setup
    case unchanged

    static func next(hasDevice: Bool, presentationActive: Bool, presentsDevice: Bool) -> ConnectViewModelUpdate {
        guard hasDevice else {
            return .reset
        }
        guard presentationActive else {
            return .suspend
        }
        return presentsDevice ? .unchanged : .setup
    }
}

#if os(macOS)
/**
 * The macOS menu bar's connection row and icon. Only the connected status
 * reads as connected: the sdk's CONNECT_FAILED can last indefinitely, and a
 * destination set, a connect in progress or a start waiting on its balance
 * is not a connection yet. The row says what the main window says
 * (ConnectStatusIndicator), and the icon shows connected only when it is.
 *
 * The one exception is a destination set from the device's location alone
 * (`fromLocation`, ConnectViewModel.connectionStatusFromLocation): with the
 * window hidden nothing reports how far the connection got, so a set
 * location reads as connected, as it always did.
 */
enum MenuBarConnectionState: Equatable {
    case connected
    case connecting
    case failed
    case disconnected

    init(_ connectionStatus: ConnectionStatus?, fromLocation: Bool = false) {
        switch connectionStatus {
        case .connected:
            self = .connected
        case .destinationSet where fromLocation:
            self = .connected
        case .connecting, .destinationSet:
            self = .connecting
        case .connectFailed:
            self = .failed
        case .disconnected, .none:
            self = .disconnected
        }
    }

    /// The SF Symbol before the label.
    var symbol: String {
        switch self {
        case .connected: return "checkmark"
        case .connecting: return "ellipsis"
        case .failed: return "exclamationmark.triangle"
        case .disconnected: return "xmark"
        }
    }

    /// Read as a checklist, like the row below it: "✓ Connected", "✗ Connected".
    var label: String {
        switch self {
        case .connected, .disconnected: return String(localized: "Connected")
        case .connecting: return String(localized: "Connecting…")
        case .failed: return String(localized: "Couldn't connect")
        }
    }

    /// The menu bar icon, with or without public providing.
    func iconName(providing: Bool) -> String {
        switch (self == .connected, providing) {
        case (true, true): return "MenuBarProvideConnect"
        case (true, false): return "MenuBarNoProvideConnect"
        case (false, true): return "MenuBarProvideNoConnect"
        case (false, false): return "MenuBarNoProvideNoConnect"
        }
    }
}
#endif

private struct PresentationActiveEnvironmentKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var presentationActive: Bool {
        get { self[PresentationActiveEnvironmentKey.self] }
        set { self[PresentationActiveEnvironmentKey.self] = newValue }
    }
}

@main
struct NetworkApp: App {
    @Environment(\.scenePhase) private var scenePhase
    
#if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
#elseif os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var mainWindow: NSWindow?
    @State private var mainWindowVisible = true
    #if DIRECT_DOWNLOAD
    // the direct-download build ships the tunnel as a system extension that
    // macOS must install (and the user approve once) before it can run
    @StateObject private var systemExtensionActivator = SystemExtensionActivator()
    // and updates itself from the official releases (the App Store build
    // updates through the store): checked at launch, throttled, and from
    // Settings
    @StateObject private var directUpdater = DirectUpdater()
    #endif
    // the per-app split tunnel (macOS 15+): the system extension and its
    // transparent proxy configuration, kept in step with the excluded apps
    @StateObject private var splitTunnelProxyController = SplitTunnelProxyController()
#endif
    
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true

    @State private var keyEventMonitor: Any?
    @State private var presentationLifecycle = PresentationLifecycleState()
    
    let themeManager = ThemeManager.shared
    let startupMode: AppStartupMode
    
    @StateObject var deviceManager: DeviceManager

    @StateObject var connectViewModel: ConnectViewModel

    @StateObject var throughputStore = ThroughputStore()
    @StateObject var blockActionsStore = BlockActionsStore()
    @StateObject var dnsSettingsStore = DnsSettingsStore()
    @StateObject var transportSettingsStore = TransportSettingsStore()
    @StateObject var networkPeersStore = NetworkPeersStore()
    @StateObject var reliabilityStore = ReliabilityStore()
    // this device's provider status from the server, for the provider statistics
    @StateObject var providerStatusStore = ProviderStatusStore()
    // what providing does on battery, and the power state (P077)
    @StateObject var providePowerStore = ProvidePowerStore()
    // where a Home Screen widget tap takes the app (urnetwork://widgets/...)
    @StateObject var deepLinkRouter = DeepLinkRouter()

    init() {
        // the app process writes its own logs too: glog writes NOTHING until a
        // log dir is set, so without this the app half of a diagnostic bundle
        // would be empty
        DiagnosticsLogLocation.configure(processName: DiagnosticsLogLocation.appProcessName)

        let startupMode = HardwareNoVPNLaunchContract.current
        self.startupMode = startupMode
        // Hosted unit tests run inside this process (XCTest sets
        // XCTestConfigurationFilePath) and build their own spaces, so the app
        // builds none: the bundled space would dial the network before any
        // test runs. UI tests launch the app as a process of its own, without
        // the variable, and keep the normal startup.
        let hostsUnitTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let deviceManager = DeviceManager(startupMode: startupMode, automaticallyInitialize: !hostsUnitTests)
        _deviceManager = StateObject(wrappedValue: deviceManager)
        let connectViewModel = ConnectViewModel()
        _connectViewModel = StateObject(wrappedValue: connectViewModel)
        appDelegate.deviceManager = deviceManager
        // every logout, the server's included, stops the account connecting
        deviceManager.logoutStarted = { [weak connectViewModel] in
            connectViewModel?.signOutStarted()
        }
        #if os(macOS)
        // every quit waits for its queued commands (QuitSequence)
        appDelegate.connectViewModel = connectViewModel
        #endif

        /**
         * Start the StoreKit transaction listener at PROCESS launch, per
         * Apple's guidance — not at MainView creation (post-login). A renewal,
         * an Ask to Buy approval, or a cross-device purchase delivered while
         * the app sits on the login screen is reported to the server, finished
         * only on a terminal answer, and recorded here — then picked up by the
         * per-network gate when its network logs in. The api provider hands
         * the monitor whatever session api exists at report time (an empty
         * byJwt means logged out, and reporting defers until login).
         */
        // not in the direct-download build: billing there is Stripe only
        // (plan: macos-direct-download.md), so there is no App Store
        // transaction stream to listen to
        #if !DIRECT_DOWNLOAD
        if startupMode != .rejectedHardwareTestRequest {
            AppStoreTransactionMonitor.shared.start(
                apiProvider: { [weak deviceManager] in
                    deviceManager?.api
                },
                sessionNetworkIdProvider: { [weak deviceManager] in
                    deviceManager?.parsedJwt?.networkId.flatMap { UUID(uuidString: $0.idStr) }
                }
            )
        }
        #endif

        #if os(iOS)
        // for styling NavigationTitle
        // todo - can probably be moved to top of app
        if let largeFont = UIFont(name: "ABCGravity-Extended", size: 32) {
            UINavigationBar.appearance().largeTitleTextAttributes = [.font: largeFont]
        }
        if let titleFont = UIFont(name: "PP NeueBit", size: 24) {
            UINavigationBar.appearance().titleTextAttributes = [.font: titleFont]
        }
        #endif
    }
    
    func setupConnectViewModel(_ device: SdkDeviceRemote) {
        
        let connectViewController = device.openConnectViewController()
        
        self.connectViewModel.setup(
            api: deviceManager.api,
            device: device,
            connectViewController: connectViewController
        )
        
    }

    func updateConnectViewModel(_ device: SdkDeviceRemote?) {
        let update = ConnectViewModelUpdate.next(
            hasDevice: device != nil,
            presentationActive: presentationLifecycle.isActive,
            presentsDevice: device != nil
                && connectViewModel.device == device
                && connectViewModel.connectViewController != nil
        )
        switch update {
        case .reset:
            connectViewModel.reset()
            resetDeviceStores()
        case .suspend:
            connectViewModel.suspend(api: deviceManager.api, device: device)
            resetDeviceStores()
        case .setup:
            if let device {
                setupConnectViewModel(device)
                setupDeviceStores(device)
            }
        case .unchanged:
            return
        }
    }

    private func setupDeviceStores(_ device: SdkDeviceRemote) {
        let localState = deviceManager.asyncLocalState?.getLocalState()
        throughputStore.setup(device)
        // the app local state mirrors the split rule, dns and transport
        // settings edits so they survive an app relaunch while the tunnel is
        // down (see the stores)
        blockActionsStore.setup(device, localState: localState)
        dnsSettingsStore.setup(device, localState: localState)
        transportSettingsStore.setup(device, localState: localState)
        networkPeersStore.setup(device)
        reliabilityStore.setup(device)
        providerStatusStore.setup(device)
    }

    private func resetDeviceStores() {
        throughputStore.reset()
        blockActionsStore.reset()
        dnsSettingsStore.reset()
        transportSettingsStore.reset()
        networkPeersStore.reset()
        reliabilityStore.reset()
        providerStatusStore.reset()
    }

    // Cold launch already gets a fresh JWT (the SDK's token manager refreshes
    // once immediately on start), but returning from the background does not
    // -- the token manager only refreshes on a schedule (~14 days out from
    // expiration) or when explicitly asked. Force one here so anything that
    // could have changed out-of-band (e.g. a network name changed from
    // another device or the web dashboard) shows up when the user comes
    // back to the app, not just after a local rename or a full logout/login.
    private func refreshJwtOnForeground() {
        do {
            try deviceManager.device?.refreshToken(0)
        } catch {
            print("Error refreshing JWT on foreground: \(error)")
        }
    }

    private func setPresentationActive(_ active: Bool) {
        guard let transition = presentationLifecycle.update(isActive: active) else {
            return
        }

        applyPresentationLifecycleTransition(transition)
    }

    private func applyPresentationLifecycleTransition(
        _ transition: PresentationLifecycleTransition
    ) {
        switch transition {
        case .resume:
            deviceManager.applicationDidBecomeActive()
            providePowerStore.applicationDidBecomeActive()
            updateConnectViewModel(deviceManager.device)
        case .suspend:
            deviceManager.applicationDidBecomeInactive()
            // inactive now: suspends, or resets with no device
            updateConnectViewModel(deviceManager.device)
        }
    }
    
    #if os(macOS)
    private var menuBarConnection: MenuBarConnectionState {
        MenuBarConnectionState(
            connectViewModel.connectionStatus,
            fromLocation: connectViewModel.connectionStatusFromLocation
        )
    }
    #endif
    
    private var provideEnabled: Bool {
        // reflect PUBLIC providing only: Network provide (same-network peers) is
        // always active, so the provider existing is not a meaningful signal. Use
        // the listener-backed cache: SwiftUI can evaluate this property repeatedly
        // while drawing the menu, and a synchronous SDK/RPC getter here stalls the
        // main actor on every evaluation.
        return deviceManager.providingPublicly
    }

    #if os(macOS)
    private var menuBarImage: String {
        menuBarConnection.iconName(providing: provideEnabled)
    }
    #endif
    
    
    var body: some Scene {
        WindowGroup {
            
            
            #if os(iOS)
            Group {
                #if DEBUG && URNETWORK_HARDWARE_UI_TESTING
                if startupMode == .rejectedHardwareTestRequest {
                    HardwareNoVPNRejectedView()
                } else if let result = ColdRelaunchIntegrationHarness.result {
                    ColdRelaunchIntegrationView(result: result)
                } else {
                    ContentView()
                }
                #elseif DEBUG
                if let result = ColdRelaunchIntegrationHarness.result {
                    ColdRelaunchIntegrationView(result: result)
                } else {
                    ContentView()
                }
                #else
                ContentView()
                #endif
            }
                .environmentObject(themeManager)
                .environmentObject(deviceManager)
                .environmentObject(connectViewModel)
                .environmentObject(throughputStore)
                .environmentObject(blockActionsStore)
                .environmentObject(dnsSettingsStore)
                .environmentObject(transportSettingsStore)
                .environmentObject(networkPeersStore)
                .environmentObject(reliabilityStore)
                .environmentObject(providerStatusStore)
                .environmentObject(providePowerStore)
                .environmentObject(deepLinkRouter)
                .environment(\.presentationActive, presentationLifecycle.isActive)
                .onOpenURL { url in
                    if let destination = WidgetDestination(url: url) {
                        // a Home Screen widget tap: the tab view and the
                        // connect view route it
                        deepLinkRouter.open(destination)
                    } else if let destination = OnboardingDestination(url: url) {
                        // an onboarding email's link, after the ur.io landing page
                        deepLinkRouter.open(destination)
                    } else if let link = Top200SignDestination(url: url) {
                        // the ur.io Top 200 page's "Open in the app": only
                        // fills the sign screen's field. Dropped while signed out
                        if deviceManager.device != nil {
                            deepLinkRouter.open(link)
                        }
                    } else {
                        GIDSignIn.sharedInstance.handle(url)
                    }
                }
                .preferredColorScheme(.dark)
                .background(themeManager.currentTheme.backgroundColor)
                .onReceive(deviceManager.$device) { device in
                    updateConnectViewModel(device)
                    #if DEBUG
                    PhysicalPeerTestDriver.runIfRequested(
                        deviceManager: deviceManager,
                        connectViewModel: connectViewModel,
                        networkPeersStore: networkPeersStore
                    )
                    #endif
                }
                .onChange(of: scenePhase) { phase in
                    setPresentationActive(phase == .active)
                    if phase == .background {
                        // pending product events go out before the system suspends the app
                        ClientEvents.shared.flush()
                    }
                    if phase == .active {
                        // a reload requested while the app is in the
                        // foreground is not charged against the widget budget,
                        // and nothing else on any app lifecycle path reloads
                        // them -- so opening the app is the reliable way to
                        // un-stick a widget the system has been deferring
                        WidgetRefresh.reloadAll()
                        WidgetPlacementReporter.report()
                        refreshJwtOnForeground()
                    }
                }
                .onAppear {
                    setPresentationActive(scenePhase == .active)
                }
                #if DEBUG
                .task {
                    PhysicalPeerTestDriver.runIfRequested(
                        deviceManager: deviceManager,
                        connectViewModel: connectViewModel,
                        networkPeersStore: networkPeersStore
                    )
                }
                #endif
            #elseif os(macOS)
            ContentView()
                // the open window takes every urnetwork:// callback (wallet
                // connect, widgets, onboarding) instead of SwiftUI opening a
                // new window for it
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
                .environmentObject(themeManager)
                .environmentObject(deviceManager)
                .environmentObject(connectViewModel)
                .environmentObject(throughputStore)
                .environmentObject(blockActionsStore)
                .environmentObject(dnsSettingsStore)
                .environmentObject(transportSettingsStore)
                .environmentObject(networkPeersStore)
                .environmentObject(reliabilityStore)
                .environmentObject(providerStatusStore)
                .environmentObject(providePowerStore)
                .environmentObject(deepLinkRouter)
                .environmentObject(splitTunnelProxyController)
                .environment(\.presentationActive, presentationLifecycle.isActive)
                .onAppear {
                    // follows the device and the rule store for the life of
                    // the process, window shown or not
                    splitTunnelProxyController.setup(
                        deviceManager: deviceManager,
                        blockActionsStore: blockActionsStore
                    )
                }
                .onOpenURL { url in
                    if let destination = WidgetDestination(url: url) {
                        // a Home Screen widget tap: the tab view and the
                        // connect view route it
                        deepLinkRouter.open(destination)
                    } else if let destination = OnboardingDestination(url: url) {
                        // an onboarding email's link, after the ur.io landing page
                        deepLinkRouter.open(destination)
                    } else if let link = Top200SignDestination(url: url) {
                        // the ur.io Top 200 page's "Open in the app": only
                        // fills the sign screen's field. Dropped while signed out
                        if deviceManager.device != nil {
                            deepLinkRouter.open(link)
                        }
                    } else if let link = BillingDeepLink(url: url) {
                        // a Stripe checkout handing control back from the
                        // browser (direct-download build): the split view
                        // routes it to the store
                        deepLinkRouter.open(link)
                    } else if let ssoReturn = browserSsoReturn(url) {
                        // the api's oauth callback handing a Google or Apple
                        // browser sign-in back (direct-download build): the
                        // login screen or the add sign-in method sheet checks
                        // it against the attempt it started
                        deepLinkRouter.open(ssoReturn)
                    } else {
                        GIDSignIn.sharedInstance.handle(url)
                    }
                }
                .preferredColorScheme(.dark)
                .background(themeManager.currentTheme.backgroundColor)
                .onAppear {
                    if keyEventMonitor == nil {
                        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                            if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "q" {
                                hideWindow()
                                return nil
                            }
                            return event
                        }
                    }
                }
                .onReceive(deviceManager.$device) { device in
                    updateConnectViewModel(device)
                }
                .onChange(of: scenePhase) { phase in
                    setMacPresentationActive(sceneActive: phase == .active)
                    if phase == .background {
                        ClientEvents.shared.flush()
                    }
                    if phase == .active {
                        // a reload requested while the app is in the
                        // foreground is not charged against the widget budget,
                        // and nothing else on any app lifecycle path reloads
                        // them -- so opening the app is the reliable way to
                        // un-stick a widget the system has been deferring
                        WidgetRefresh.reloadAll()
                        WidgetPlacementReporter.report()
                        refreshJwtOnForeground()
                    }
                }
                #if DIRECT_DOWNLOAD
                .environmentObject(systemExtensionActivator)
                .sheet(isPresented: $systemExtensionActivator.isPromptPresented) {
                    SystemExtensionApprovalView()
                        .environmentObject(systemExtensionActivator)
                        .environmentObject(themeManager)
                }
                .onAppear {
                    // at launch, and again before every connect (activation
                    // is idempotent; the second call re-prompts a skipped
                    // approval)
                    systemExtensionActivator.activateIfNeeded()
                    connectViewModel.beforeConnect = { [weak systemExtensionActivator] in
                        systemExtensionActivator?.activateIfNeeded()
                    }
                }
                .environmentObject(directUpdater)
                .onAppear {
                    // the launch update check: at most once per six hours,
                    // after the startup rush, only while enabled in Settings
                    directUpdater.checkAtLaunchIfDue()
                }
                #endif
                .onAppear {
                    if mainWindow == nil {
                        mainWindow = NSApplication.shared.windows.first { window in
                            window.styleMask.contains(.titled) &&
                            window.styleMask.contains(.closable) &&
                            !window.styleMask.contains(.nonactivatingPanel)
                        }
                        mainWindow?.isReleasedWhenClosed = false
                    }
                    setMainWindowVisible(
                        mainWindow?.isVisible == true &&
                        mainWindow?.isMiniaturized == false &&
                        mainWindow?.occlusionState.contains(.visible) == true
                    )
                }
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: NSWindow.didChangeOcclusionStateNotification
                    )
                ) { notification in
                    updateMainWindowVisibility(notification)
                }
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: NSWindow.willCloseNotification
                    )
                ) { notification in
                    updateMainWindowVisibility(notification, visible: false)
                }
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: NSWindow.didMiniaturizeNotification
                    )
                ) { notification in
                    updateMainWindowVisibility(notification, visible: false)
                }
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: NSWindow.didDeminiaturizeNotification
                    )
                ) { notification in
                    updateMainWindowVisibility(notification)
                }
            #endif
            
        }
        #if os(macOS)
        .defaultSize(CGSize(width: 1024, height: 768))
        #endif
        .commands {
            
            /**
             * macOS menu items
             */
            
            #if os(macOS)
            CommandGroup(replacing: .appTermination) {
                Button("Quit URnetwork") {
                    quitDisconnecting()
                }
            }
            #endif
            
            if deviceManager.device != nil {
             
                CommandMenu("Account") {
                    Button("Sign out") {
                        
                        // no connect from here, then the disconnect
                        connectViewModel.beginSignOut()

                        Task {
                            // the disconnect reaches the sdk before the sign out
                            await connectViewModel.connectCommandsSettled()
                            deviceManager.logout()
                        }
                        
                    }
                }
                
            }
            
        }
        #if os(macOS)
        MenuBarExtra(
            "URnetwork System Menu",
            image: menuBarImage,
            isInserted: $showMenuBarExtra
        ) {
            
            Text("URnetwork Status")
                .font(.headline)
            

            Button(action: {}) {
                HStack {
                    Image(systemName: menuBarConnection.symbol)
                    Text(menuBarConnection.label)
                }
            }
            .buttonStyle(.plain)
            .disabled(true)

            Button(action: {}) {
                HStack {
                    Image(systemName: self.provideEnabled ? "checkmark" : "xmark")
                    Text("Providing")
                }
            }
            .buttonStyle(.plain)
            .disabled(true)
            
            Divider()
            
            if connectViewModel.connectionStatus == .disconnected {
                Button("Connect", action: {
                    // out of balance the start is refused for the upgrade
                    // sheet, which lives in the main window
                    connectViewModel.connect(onUpgrade: { showWindow() })
                })
            } else {
                Button("Disconnect", action: {
                    connectViewModel.disconnect()
                })
            }
            
            Button("Show", action: {
                showWindow()
            })
            
            Button("Quit URnetwork", action: {
                quitDisconnecting()
            })
            
            
        }
        #endif
    }
    
    #if os(macOS)

    private func setMacPresentationActive(sceneActive: Bool) {
        guard let transition = presentationLifecycle.update(
            sceneActive: sceneActive,
            presentationVisible: mainWindowVisible
        ) else {
            return
        }

        applyPresentationLifecycleTransition(transition)
    }

    private func setMainWindowVisible(_ visible: Bool) {
        mainWindowVisible = visible
        setMacPresentationActive(sceneActive: scenePhase == .active)
    }

    private func updateMainWindowVisibility(
        _ notification: Notification
    ) {
        guard
            let window = notification.object as? NSWindow,
            let mainWindow,
            window === mainWindow
        else {
            return
        }
        setMainWindowVisible(
            window.isVisible &&
            !window.isMiniaturized &&
            window.occlusionState.contains(.visible)
        )
    }

    private func updateMainWindowVisibility(
        _ notification: Notification,
        visible: Bool
    ) {
        guard
            let window = notification.object as? NSWindow,
            let mainWindow,
            window === mainWindow
        else {
            return
        }
        setMainWindowVisible(visible)
    }
    
    /// The Google or Apple browser sign-in return (urnetwork://oauth/<provider>)
    /// the direct-download build routes; the App Store build has the native
    /// SDKs and leaves every other url to GIDSignIn.
    private func browserSsoReturn(_ url: URL) -> BrowserSso.Return? {
        #if DIRECT_DOWNLOAD
        return BrowserSso.parseReturn(url)
        #else
        return nil
        #endif
    }

    /// The app menu's and the menu bar's Quit: disconnects, then quits. The
    /// quit waits for the disconnect to reach the sdk, as every quit waits
    /// for its queued commands (QuitSequence), without blocking the main
    /// actor.
    private func quitDisconnecting() {
        connectViewModel.disconnect()
        NSApplication.shared.terminate(nil)
    }

    private func hideWindow() {
        setMainWindowVisible(false)
        mainWindow?.orderOut(nil)  // Hide the window without destroying it
        NSApp.setActivationPolicy(.accessory)  // Remove from Dock
    }

    private func showWindow() {
        NSApp.setActivationPolicy(.regular)  // Show in Dock

        if let window = mainWindow {
            window.makeKeyAndOrderFront(nil)
        }
        
        NSApplication.shared.activate(ignoringOtherApps: true)
        setMainWindowVisible(true)
    }
    
    #endif
    
}

#if DEBUG && URNETWORK_HARDWARE_UI_TESTING && os(iOS)
private struct HardwareNoVPNRejectedView: View {
    var body: some View {
        Text("rejected")
            .accessibilityIdentifier("hardware.startup.request-rejected")
    }
}
#endif

#if DEBUG && os(iOS)
private enum ColdRelaunchIntegrationHarness {
    static let result: String? = runIfRequested()

    private static func runIfRequested() -> String? {
        let environment = ProcessInfo.processInfo.environment
        guard let mode = environment["UR_COLD_RELAUNCH_MODE"],
              let runId = environment["UR_COLD_RELAUNCH_RUN_ID"],
              !runId.isEmpty else {
            return nil
        }
        let instanceId = "cold-relaunch-\(runId)"
        let rpcAccount = "cold-relaunch-rpc-\(runId)"
        let freshJwt = jwt(issuedAt: 2_000_000_000, expiresAt: 4_000_000_000)
        let olderJwt = jwt(issuedAt: 1_900_000_000, expiresAt: 3_900_000_000)
        let rpcSession = RpcSession(
            clientPem: "test-client-private-\(runId)",
            clientCertPem: "test-client-public-\(runId)",
            serverPem: "test-server-private-\(runId)",
            serverCertPem: "test-server-public-\(runId)",
            host: "127.0.0.1",
            port: 12_025
        )

        switch mode {
        case "seed":
            SharedTunnelJwtStore.remove(expectedInstanceId: instanceId)
            RpcSessionStore.testingClear(account: rpcAccount)
            guard SharedTunnelJwtStore.save(
                byJwt: freshJwt,
                instanceId: instanceId
            ), RpcSessionStore.testingSave(
                rpcSession,
                state: .confirmed,
                account: rpcAccount
            ) else {
                return "seed-failed"
            }
            return "seeded"

        case "verify":
            // Simulate a delayed response from an older refresh after the
            // process relaunch. Immutable token records must retain freshJwt.
            let delayedSave = SharedTunnelJwtStore.save(
                byJwt: olderJwt,
                instanceId: instanceId
            )
            let jwtRestored = SharedTunnelJwtStore.load(
                expectedInstanceId: instanceId
            ) == freshJwt
            let wrongInstanceRejected = SharedTunnelJwtStore.load(
                expectedInstanceId: instanceId + "-other"
            ) == nil
            let rpcRestored: Bool
            switch RpcSessionStore.testingLoadResult(account: rpcAccount) {
            case .confirmed(let restored):
                rpcRestored = restored == rpcSession
            case .missing, .pending, .corrupt, .unavailable:
                rpcRestored = false
            }
            SharedTunnelJwtStore.remove(expectedInstanceId: instanceId)
            RpcSessionStore.testingClear(account: rpcAccount)
            return delayedSave && jwtRestored && wrongInstanceRejected && rpcRestored
                ? "verified"
                : "verify-failed"

        default:
            return "unknown-mode"
        }
    }

    private static func jwt(issuedAt: Int64, expiresAt: Int64) -> String {
        let payload = try! JSONSerialization.data(withJSONObject: [
            "iat": issuedAt,
            "exp": expiresAt,
        ])
        func base64URL(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return "e30.\(base64URL(payload)).integration-signature"
    }
}

private struct ColdRelaunchIntegrationView: View {
    let result: String

    var body: some View {
        Text(result)
            .accessibilityIdentifier("integration.cold-relaunch.result")
    }
}
#endif
