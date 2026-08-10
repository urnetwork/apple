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
#endif
    
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true

    @State private var keyEventMonitor: Any?
    @State private var presentationLifecycle = PresentationLifecycleState()
    
    let themeManager = ThemeManager.shared
    
    @StateObject var deviceManager: DeviceManager

    @StateObject var connectViewModel = ConnectViewModel()

    @StateObject var throughputStore = ThroughputStore()
    @StateObject var blockActionsStore = BlockActionsStore()
    @StateObject var dnsSettingsStore = DnsSettingsStore()
    @StateObject var networkPeersStore = NetworkPeersStore()
    @StateObject var reliabilityStore = ReliabilityStore()

    init() {
        let deviceManager = DeviceManager()
        _deviceManager = StateObject(wrappedValue: deviceManager)
        appDelegate.deviceManager = deviceManager

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
        AppStoreTransactionMonitor.shared.start(apiProvider: { [weak deviceManager] in
            deviceManager?.api
        })

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
        guard presentationLifecycle.isActive else {
            connectViewModel.suspend(api: deviceManager.api, device: device)
            resetDeviceStores()
            return
        }

        if let device = device {
            if connectViewModel.device == device && connectViewModel.connectViewController != nil {
                return
            }
            setupConnectViewModel(device)
            setupDeviceStores(device)
        } else {
            connectViewModel.reset()
            resetDeviceStores()
        }
    }

    private func setupDeviceStores(_ device: SdkDeviceRemote) {
        throughputStore.setup(device)
        blockActionsStore.setup(device)
        dnsSettingsStore.setup(device)
        networkPeersStore.setup(device)
        reliabilityStore.setup(device)
    }

    private func resetDeviceStores() {
        throughputStore.reset()
        blockActionsStore.reset()
        dnsSettingsStore.reset()
        networkPeersStore.reset()
        reliabilityStore.reset()
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
            updateConnectViewModel(deviceManager.device)
        case .suspend:
            connectViewModel.suspend(api: deviceManager.api, device: deviceManager.device)
            resetDeviceStores()
        }
    }
    
    private var connectEnabled: Bool {
        guard let connectionStatus = connectViewModel.connectionStatus else {
            return false
        }
        return connectionStatus != .disconnected
    }
    
    private var provideEnabled: Bool {
        // reflect PUBLIC providing only: Network provide (same-network peers) is
        // always active, so the provider existing is not a meaningful signal. Use
        // the listener-backed cache: SwiftUI can evaluate this property repeatedly
        // while drawing the menu, and a synchronous SDK/RPC getter here stalls the
        // main actor on every evaluation.
        return deviceManager.providingPublicly
    }

    private var menuBarImage: String {
        
        if self.connectEnabled {
            
            // connect and provide enabled
            if self.provideEnabled {
                return "MenuBarProvideConnect"
            }
            
            // connected and provide disabled
            return "MenuBarNoProvideConnect"
            
        } else {
            
            // disconnected with provide enabled
            if self.provideEnabled {
                return "MenuBarProvideNoConnect"
            }
            
            // disconnected and provide disabled
            return "MenuBarNoProvideNoConnect"
            
        }
        
    }
    
    
    var body: some Scene {
        WindowGroup {
            
            
            #if os(iOS)
            ContentView()
                .environmentObject(themeManager)
                .environmentObject(deviceManager)
                .environmentObject(connectViewModel)
                .environmentObject(throughputStore)
                .environmentObject(blockActionsStore)
                .environmentObject(dnsSettingsStore)
                .environmentObject(networkPeersStore)
                .environmentObject(reliabilityStore)
                .environment(\.presentationActive, presentationLifecycle.isActive)
                .onOpenURL { url in
                    GIDSignIn.sharedInstance.handle(url)
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
                    if phase == .active {
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
                .environmentObject(themeManager)
                .environmentObject(deviceManager)
                .environmentObject(connectViewModel)
                .environmentObject(throughputStore)
                .environmentObject(blockActionsStore)
                .environmentObject(dnsSettingsStore)
                .environmentObject(networkPeersStore)
                .environmentObject(reliabilityStore)
                .environment(\.presentationActive, presentationLifecycle.isActive)
                .onOpenURL { url in
                    GIDSignIn.sharedInstance.handle(url)
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
                    if phase == .active {
                        refreshJwtOnForeground()
                    }
                }
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
                    connectViewModel.disconnect()
                    
                    NSApplication.shared.terminate(nil)
                }
            }
            #endif
            
            if deviceManager.device != nil {
             
                CommandMenu("Account") {
                    Button("Sign out") {
                        
                        connectViewModel.disconnect()
                        
                        Task {
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
                    Image(systemName: self.connectEnabled ? "checkmark" : "xmark")
                    Text("Connected")
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
                    connectViewModel.connect()
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
                connectViewModel.disconnect()
                
                NSApplication.shared.terminate(nil)
                
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
