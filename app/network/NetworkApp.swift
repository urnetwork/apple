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
    @State private var mainWindowController: NSWindowController?
    #endif
    
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true
    
    @State private var isWindowVisible = true
    
    let themeManager = ThemeManager.shared
    
    @StateObject var deviceManager = DeviceManager()
    
    @StateObject var connectViewModel = ConnectViewModel()
    
    func setupConnectViewModel(_ device: SdkDeviceRemote) {
        
        let connectViewController = device.openConnectViewController()
        
        self.connectViewModel.setup(
            api: deviceManager.api,
            device: device,
            connectViewController: connectViewController
        )
        
    }
    
    private var menuBarImage: String {
        
        let provideWhileDisconnected = deviceManager.provideWhileDisconnected
        
        switch connectViewModel.connectionStatus {
        case .connected:
            
            if provideWhileDisconnected {
                return "MenuBarProvideConnect"
            } else {
                return "MenuBarNoProvideConnect"
            }
            
        default:
            if provideWhileDisconnected {
                return "MenuBarProvideNoConnect"
            } else {
                return "MenuBarNoProvideNoConnect"
            }
            
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
            #endif
            
        }
        .commands {
            
            /**
             * macOS menu items
             */
            
            #if os(macOS)
            CommandGroup(replacing: .appTermination) {
                Button("Quit URnetwork") {
                    NSApplication.shared.terminate(nil)
                }
            }
            #endif
            
            if deviceManager.device != nil {
             
                CommandMenu("Account") {
                    Button("Sign out") {
                        deviceManager.logout()
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
            Button("Show", action: {
                showWindow()
            })
            Divider()
            Button("Quit URnetwork", action: {
                connectViewModel.disconnect()
                
                Task {
                    if let vpnManager = deviceManager.vpnManager {
                        await vpnManager.close()
                    }
                    NSApplication.shared.terminate(nil)
                }
                
            })
            
        }
        #endif
    }
    
    #if os(macOS)
    private func hideWindow() {

        NSApplication.shared.windows
         .filter { window in
             // Only close windows that are:
             // - Not the MenuBarExtra (nonactivatingPanel)
             // - Main application windows (titled, closable, etc)
             !window.styleMask.contains(.nonactivatingPanel) &&
             window.styleMask.contains(.titled) &&
             window.styleMask.contains(.closable)
         }
         .forEach { $0.close() }

        NSApp.setActivationPolicy(.accessory)

        isWindowVisible = false
    }
    
    private func showWindow() {
        NSApp.setActivationPolicy(.regular)

        if mainWindowController == nil {
            let contentView = ContentView()
                .environmentObject(themeManager)
                .environmentObject(deviceManager)
                .environmentObject(connectViewModel)
                .preferredColorScheme(.dark)
                .background(themeManager.currentTheme.backgroundColor)

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 500),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.contentView = NSHostingView(rootView: contentView)
            window.center()

            mainWindowController = NSWindowController(window: window)
        }

        mainWindowController?.showWindow(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)

        isWindowVisible = true
    }
    #endif
    
}
