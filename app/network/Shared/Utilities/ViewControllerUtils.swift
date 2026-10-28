//
//  ViewControllerUtils.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2024/12/06.
//

import Foundation

#if os(iOS)
// used for google sign in
import SwiftUI
import UIKit

/**
 * The window a SwiftUI view is in, so a UIKit presenter (Google sign-in)
 * opens in the scene that asked for it, not whichever scene connected first.
 * A view fills it with `readsHostingWindow(_:)`.
 */
final class HostingWindow {

    weak var window: UIWindow?

    /// The view controller to present from: the top of the window's
    /// presentations, so a request made in a sheet presents over the sheet.
    var presenter: UIViewController? {
        var top = window?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}

private struct HostingWindowReader: UIViewRepresentable {

    let hostingWindow: HostingWindow

    func makeUIView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.isUserInteractionEnabled = false
        view.hostingWindow = hostingWindow
        return view
    }

    func updateUIView(_ view: ReaderView, context: Context) {
        view.hostingWindow = hostingWindow
        hostingWindow.window = view.window
    }

    final class ReaderView: UIView {
        var hostingWindow: HostingWindow?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            hostingWindow?.window = window
        }
    }
}

extension View {

    /// Keeps `hostingWindow` on the window this view is in.
    func readsHostingWindow(_ hostingWindow: HostingWindow) -> some View {
        background(HostingWindowReader(hostingWindow: hostingWindow))
    }
}
#endif
