//
//  WidgetPlacementReporter.swift
//  URnetwork
//
//  Reports the widget kinds the user has placed, once each, as product events.
//  WidgetKit lists the placed widgets; the Control Center control is not a
//  widget configuration and is not reported here.
//

import Foundation
import WidgetKit

enum WidgetPlacementReporter {

    static func report() {
        WidgetCenter.shared.getCurrentConfigurations { result in
            guard case .success(let infos) = result else { return }
            let kinds = infos.compactMap { WidgetEventKind.name(forWidgetKind: $0.kind) }
            guard !kinds.isEmpty else { return }
            Task { @MainActor in
                ClientEvents.shared.widgetsPlaced(kinds: kinds)
            }
        }
    }
}
