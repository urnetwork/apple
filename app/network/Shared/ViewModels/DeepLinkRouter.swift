//
//  DeepLinkRouter.swift
//  URnetwork
//
//  Holds a widget tap's destination until the view that can show it is on
//  screen: the tab view switches to the connect tab as soon as one is
//  pending, and the connect view presents the sheet (provider details or
//  client contracts) and consumes it. Pending survives the welcome animation
//  and a tab that is not yet mounted, so a cold launch from a widget lands on
//  the right screen too.
//

import Combine
import Foundation

@MainActor
final class DeepLinkRouter: ObservableObject {

    @Published private(set) var pending: WidgetDestination? = nil

    func open(_ destination: WidgetDestination) {
        pending = destination
    }

    /// Takes the pending destination, if any.
    func consume() -> WidgetDestination? {
        let destination = pending
        pending = nil
        return destination
    }
}
