//
//  UrSnackbarManager.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2024/12/07.
//

import Foundation

/// The app's one snackbar. A message stays up long enough to read: a short
/// confirmation for a few seconds, a long server message (an account deletion
/// the App Store refused runs to a paragraph) for its reading time. A tap
/// dismisses it early.
@MainActor
class UrSnackbarManager: ObservableObject {

    // a short message's display time
    nonisolated static let minimumSeconds: TimeInterval = 3
    // the longest display, so a snackbar always goes away
    nonisolated static let maximumSeconds: TimeInterval = 20
    // reading speed
    nonisolated static let charactersPerSecond: Double = 15

    /// Runs `hide` after `seconds`. Tests pass a recorder instead of the main queue.
    typealias ScheduleHide = (_ seconds: TimeInterval, _ hide: @escaping @MainActor () -> Void) -> Void

    @Published private(set) var message: String = ""
    @Published private(set) var isVisible: Bool = false

    private let scheduleHide: ScheduleHide
    // only the latest message's hide applies
    private var shownCount = 0

    init(scheduleHide: @escaping ScheduleHide = UrSnackbarManager.hideOnMainQueue) {
        self.scheduleHide = scheduleHide
    }

    func showSnackbar(message: String) {
        shownCount += 1
        let shown = shownCount

        self.message = message
        self.isVisible = true

        scheduleHide(Self.displaySeconds(for: message)) { [weak self] in
            guard let self, self.shownCount == shown else {
                return
            }
            self.isVisible = false
        }
    }

    /// Hides the message now (a tap on the snackbar).
    func dismiss() {
        shownCount += 1
        isVisible = false
    }

    /// The display time for `message`: its reading time plus a moment to
    /// notice it, between the minimum and the maximum.
    nonisolated static func displaySeconds(for message: String) -> TimeInterval {
        let readingSeconds = 1.5 + Double(message.count) / charactersPerSecond
        return min(max(minimumSeconds, readingSeconds), maximumSeconds)
    }

    nonisolated static func hideOnMainQueue(_ seconds: TimeInterval, _ hide: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            MainActor.assumeIsolated {
                hide()
            }
        }
    }

}
