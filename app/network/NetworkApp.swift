//
//  NetworkApp.swift
//  network
//
//  Created by brien on 11/18/24.
//

import SwiftUI
import URnetworkSdk
import GoogleSignIn

@main
struct NetworkApp: App {
    
#if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
#elseif os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var mainWindow: NSWindow?
#endif
    
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true
    
    @State private var isWindowVisible = true
    
    let themeManager = ThemeManager.shared
    
    @StateObject var deviceManager = DeviceManager()
    
    @StateObject var connectViewModel = ConnectViewModel()
    
    init() {
        #if os(macOS)
        appDelegate.deviceManager = deviceManager
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
    
    private var connectEnabled: Bool {
        
        guard let device = deviceManager.device else {
            return false
        }
        
        return device.getConnectEnabled()
        
    }
    
    private var provideEnabled: Bool {
        guard let device = deviceManager.device else {
            return false
        }
        
        return device.getProvideEnabled()
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
                .onOpenURL { url in
                    GIDSignIn.sharedInstance.handle(url)
                }
                .preferredColorScheme(.dark)
                .background(themeManager.currentTheme.backgroundColor)
                .onReceive(deviceManager.$device) { device in
                    
                    if let device = device {
                        setupConnectViewModel(device)
                    }
                    
                }
            #elseif os(macOS)
            ContentView()
                .environmentObject(themeManager)
                .environmentObject(deviceManager)
                .environmentObject(connectViewModel)
                .onOpenURL { url in
                    GIDSignIn.sharedInstance.handle(url)
                }
                .preferredColorScheme(.dark)
                .background(themeManager.currentTheme.backgroundColor)
                .onReceive(NSApplication.shared.publisher(for: \.isActive)) { active in
                    NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "q" {
                            hideWindow()
                            return nil
                        }
                        return event
                    }
                }
                .onReceive(deviceManager.$device) { device in
                    
                    if let device = device {
                        setupConnectViewModel(device)
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
                }
            #endif
            
        }
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
                            if let vpnManager = deviceManager.vpnManager {
                                await vpnManager.close()
                            }
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
    
    private func hideWindow() {
        mainWindow?.orderOut(nil)  // Hide the window without destroying it
        NSApp.setActivationPolicy(.accessory)  // Remove from Dock
        isWindowVisible = false
    }

    private func showWindow() {
        NSApp.setActivationPolicy(.regular)  // Show in Dock

        if let window = mainWindow {
            window.makeKeyAndOrderFront(nil)
        }
        
        NSApplication.shared.activate(ignoringOtherApps: true)
        isWindowVisible = true
    }
    
    #endif
    
}

