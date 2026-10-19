//
//  HomeLocationsRefresh.swift
//  URnetwork
//

import SwiftUI

/// Keeps the provider list store's periodic locations refresh running while
/// the home screen is on screen and the scene is active, and stopped otherwise
/// (another tab, app in the background).
struct HomeLocationsRefresh: ViewModifier {
    let providerListStore: ProviderListStore

    @Environment(\.scenePhase) private var scenePhase
    @State private var appeared = false

    func body(content: Content) -> some View {
        content
            .onAppear {
                appeared = true
                update()
            }
            .onDisappear {
                appeared = false
                update()
            }
            .onChange(of: scenePhase) { _ in
                update()
            }
    }

    private func update() {
        providerListStore.setHomeVisible(appeared && scenePhase == .active)
    }
}
