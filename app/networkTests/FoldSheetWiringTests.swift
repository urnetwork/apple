//
//  FoldSheetWiringTests.swift
//  networkTests
//

#if os(iOS)
import SwiftUI
import Testing
import UIKit
@testable import URnetwork

/**
 * The sheet modifier against UIKit's own sheet. Presented for real in a
 * window of the test host, a sheet takes its side from the window's
 * placement (UIKit's `preferredPlacement`), and without one keeps the
 * system's automatic placement, as every sheet had before. The placement is
 * injected as the window root would publish it: there is no fold here.
 */
@MainActor
@Suite(.serialized)
struct FoldSheetWiringTests {

    /// Shows `root`, which presents a sheet at once, in a fresh window, and
    /// returns the sheet's presentation controller once it is up.
    private func presentedSheet(from root: some View) async throws -> (UISheetPresentationController, UIWindow) {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: root)
        window.rootViewController = host
        window.makeKeyAndVisible()
        for _ in 0..<100 {
            if host.presentedViewController?.sheetPresentationController != nil {
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        let sheet = try #require(host.presentedViewController?.sheetPresentationController)
        return (sheet, window)
    }

    /// A sheet through the app's modifier, under the window's placement.
    private func sheetOffTheFold(placement: SheetPlacement?) async throws -> (UISheetPresentationController, UIWindow) {
        try await presentedSheet(
            from: Color.clear
                .sheetOffTheFold(isPresented: .constant(true)) {
                    Text(verbatim: "sheet")
                }
                .environment(\.sheetPlacement, placement)
        )
    }

    private func close(_ window: UIWindow) {
        window.rootViewController?.dismiss(animated: false)
        window.isHidden = true
    }

    @Test func withoutAPlacementTheSheetIsAPlainSheet() async throws {
        guard #available(iOS 27.0, *) else { return }
        let (plain, plainWindow) = try await presentedSheet(
            from: Color.clear.sheet(isPresented: .constant(true)) {
                Text(verbatim: "sheet")
            }
        )
        let plainPlacement = plain.preferredPlacement
        close(plainWindow)

        let (sheet, window) = try await sheetOffTheFold(placement: nil)
        #expect(sheet.preferredPlacement == plainPlacement)
        close(window)
    }

    @Test func aPlacementSetsTheSheetsSide() async throws {
        guard #available(iOS 27.0, *) else { return }
        let (trailing, trailingWindow) = try await sheetOffTheFold(placement: SheetPlacement(side: .trailing, maxWidth: 423))
        #expect(trailing.preferredPlacement == .trailing)
        close(trailingWindow)

        let (leading, leadingWindow) = try await sheetOffTheFold(placement: SheetPlacement(side: .leading, maxWidth: 423))
        #expect(leading.preferredPlacement == .leading)
        close(leadingWindow)
    }

    // what the modifier relies on: a presentation modifier on a clear
    // background in the sheet's content reaches the sheet as one on the
    // content itself does
    @Test func aPresentationModifierOnABackgroundReachesTheSheet() async throws {
        guard #available(iOS 27.0, *) else { return }
        let (onContent, contentWindow) = try await presentedSheet(
            from: Color.clear.sheet(isPresented: .constant(true)) {
                Text(verbatim: "sheet")
                    .presentationPlacement(.leading)
            }
        )
        #expect(onContent.preferredPlacement == .leading)
        close(contentWindow)

        let (onBackground, backgroundWindow) = try await presentedSheet(
            from: Color.clear.sheet(isPresented: .constant(true)) {
                Text(verbatim: "sheet")
                    .background {
                        Color.clear
                            .presentationPlacement(.leading)
                    }
            }
        )
        #expect(onBackground.preferredPlacement == .leading)
        close(backgroundWindow)
    }
}
#endif
