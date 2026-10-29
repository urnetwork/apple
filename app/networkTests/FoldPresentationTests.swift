//
//  FoldPresentationTests.swift
//  networkTests
//

import CoreGraphics
import Foundation
import Testing
@testable import URnetwork

/**
 * Sheets and window-wide overlays off the fold (apple/DUO.md item 11). While
 * an iPhone Duo is partly folded like a book, a sheet goes to the trailing
 * pane, the side the system moves its alerts to, no wider than that pane less
 * a margin on each side, and the snackbar, the can't-reach banner and the
 * referral celebration keep to the same pane. A fold that leaves the trailing
 * pane too narrow sends them to the leading one. Without a fold, with a flat
 * hinge, or folded in tabletop, nothing moves: the system's presentation is
 * the one there is today.
 */
struct FoldPresentationTests {

    // iPhone Duo's inner display, at 3x: 669 x 951 pt
    private static let duoLandscape = CGSize(width: 951, height: 669)
    private static let duoPortrait = CGSize(width: 669, height: 951)

    /// Partly folded like a book: the fold runs top to bottom, its frame
    /// taking in the margins interactive content keeps clear of.
    private static let book = WindowFold(frame: CGRect(x: 455, y: 0, width: 41, height: 669), isActive: true)

    private static func wholeWindow(_ size: CGSize) -> CGRect {
        CGRect(origin: .zero, size: size)
    }

    // MARK: nothing moves

    @Test func withoutAFoldNothingMoves() {
        // iPhone 18 Pro, an iPad, a Mac window, a closed iPhone Duo
        let windows = [
            CGSize(width: 402, height: 874),
            CGSize(width: 1194, height: 834),
            CGSize(width: 1200, height: 800),
            CGSize(width: 466, height: 678),
        ]
        for size in windows {
            #expect(SplitLayout.presentationPane(size: size, fold: nil) == nil)
            #expect(SplitLayout.sheetPlacement(size: size, fold: nil) == nil)
            #expect(SplitLayout.overlayFrame(size: size, fold: nil) == Self.wholeWindow(size))
        }
    }

    @Test func aFlatHingeMovesNothing() {
        // fully open, the fold is inactive and zero wide: the system centers
        // a sheet on the inner display, and it moves only once folded
        let flat = WindowFold(frame: CGRect(x: 475.5, y: 0, width: 0, height: 669), isActive: false)
        #expect(SplitLayout.sheetPlacement(size: Self.duoLandscape, fold: flat) == nil)
        #expect(SplitLayout.overlayFrame(size: Self.duoLandscape, fold: flat) == Self.wholeWindow(Self.duoLandscape))
    }

    @Test func inTabletopTheSystemPlacesTheSheet() {
        // the fold runs across the window: a sheet has no vertical placement,
        // and the overlays already sit at the top or the bottom edge
        let tabletop = WindowFold(frame: CGRect(x: 0, y: 455, width: 669, height: 41), isActive: true)
        #expect(SplitLayout.presentationPane(size: Self.duoPortrait, fold: tabletop) == nil)
        #expect(SplitLayout.sheetPlacement(size: Self.duoPortrait, fold: tabletop) == nil)
        #expect(SplitLayout.overlayFrame(size: Self.duoPortrait, fold: tabletop) == Self.wholeWindow(Self.duoPortrait))
    }

    @Test func aFoldOutsideTheWindowMovesNothing() {
        let beyond = WindowFold(frame: CGRect(x: 960, y: 0, width: 41, height: 669), isActive: true)
        #expect(SplitLayout.sheetPlacement(size: Self.duoLandscape, fold: beyond) == nil)
        #expect(SplitLayout.overlayFrame(size: Self.duoLandscape, fold: beyond) == Self.wholeWindow(Self.duoLandscape))
    }

    // MARK: folded like a book

    @Test func theTrailingPaneStartsWhereTheFoldsMarginsEnd() {
        let pane = SplitLayout.presentationPane(size: Self.duoLandscape, fold: Self.book)
        #expect(pane == FoldPresentationPane(side: .trailing, frame: CGRect(x: 496, y: 0, width: 455, height: 669)))
    }

    @Test func aSheetGoesToTheTrailingPaneNoWiderThanIt() {
        let placement = SplitLayout.sheetPlacement(size: Self.duoLandscape, fold: Self.book)
        #expect(placement == SheetPlacement(side: .trailing, maxWidth: 455 - 2 * SplitLayout.sheetPaneMargin))
    }

    @Test func aWindowWideOverlayKeepsToTheSheetsPane() {
        let frame = SplitLayout.overlayFrame(size: Self.duoLandscape, fold: Self.book)
        #expect(frame == CGRect(x: 496, y: 0, width: 455, height: 669))
        #expect(Self.book.frame.maxX <= frame.minX)
    }

    @Test func aSheetAgainstItsEdgeStaysClearOfTheFold() {
        // for any window the fold divides, on either side, the widest sheet,
        // held against the pane's outer edge by up to two margins of the
        // system's own, never reaches the fold, and it keeps the pane's
        // margin when centered
        var sides: Set<String> = []
        for width in stride(from: CGFloat(700), through: 1400, by: 50) {
            let size = CGSize(width: width, height: 700)
            for foldX in stride(from: (width * 0.3).rounded(), through: width * 0.75, by: 10) {
                let fold = WindowFold(frame: CGRect(x: foldX, y: 0, width: 41, height: 700), isActive: true)
                guard let pane = SplitLayout.presentationPane(size: size, fold: fold),
                      let placement = SplitLayout.sheetPlacement(size: size, fold: fold) else {
                    Issue.record("no pane for a fold at \(foldX) in a \(width) pt window")
                    continue
                }
                #expect(placement.side == pane.side)
                sides.insert("\(pane.side)")
                for systemMargin in stride(from: CGFloat(0), through: 2 * SplitLayout.sheetPaneMargin, by: 8) {
                    switch pane.side {
                    case .trailing:
                        #expect(fold.frame.maxX <= width - systemMargin - placement.maxWidth)
                    case .leading:
                        #expect(systemMargin + placement.maxWidth <= fold.frame.minX)
                    }
                }
                #expect(placement.maxWidth + 2 * SplitLayout.sheetPaneMargin == pane.frame.width)
            }
        }
        #expect(sides == ["leading", "trailing"])
    }

    // MARK: Split View

    @Test func beforeAnotherAppTheWiderPaneTakesTheSheet() {
        // URnetwork in two thirds of the open display, on the left: the fold
        // leaves the trailing pane a sliver, so the sheet takes the leading one
        let window = CGSize(width: 634, height: 669)
        let placement = SplitLayout.sheetPlacement(size: window, fold: Self.book)
        #expect(placement == SheetPlacement(side: .leading, maxWidth: 455 - 2 * SplitLayout.sheetPaneMargin))
        #expect(SplitLayout.overlayFrame(size: window, fold: Self.book) == CGRect(x: 0, y: 0, width: 455, height: 669))
    }

    @Test func afterAnotherAppTheTrailingPaneStillTakesIt() {
        // the same two thirds on the right: in the window's coordinates the
        // fold is near its leading edge
        let window = CGSize(width: 634, height: 669)
        let fold = WindowFold(frame: CGRect(x: 138, y: 0, width: 41, height: 669), isActive: true)
        #expect(SplitLayout.sheetPlacement(size: window, fold: fold) == SheetPlacement(side: .trailing, maxWidth: 455 - 2 * SplitLayout.sheetPaneMargin))
    }

    @Test func aFoldThatLeavesNoPaneWideEnoughMovesNothing() {
        // neither side holds a quarter of the window
        let wide = WindowFold(frame: CGRect(x: 200, y: 0, width: 551, height: 669), isActive: true)
        #expect(SplitLayout.presentationPane(size: Self.duoLandscape, fold: wide) == nil)
        #expect(SplitLayout.overlayFrame(size: Self.duoLandscape, fold: wide) == Self.wholeWindow(Self.duoLandscape))
    }

    // MARK: the wiring

    // …/apple/app/networkTests/FoldPresentationTests.swift -> …/apple/app
    private static let appRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static func source(_ path: String) throws -> String {
        try String(contentsOf: appRoot.appendingPathComponent(path), encoding: .utf8)
    }

    // every sheet in the app presents through the one modifier, so none is
    // left centered on the fold
    @Test func everySheetPresentsOffTheFold() throws {
        let network = Self.appRoot.appendingPathComponent("network")
        let files = try #require(FileManager.default.enumerator(at: network, includingPropertiesForKeys: nil))
        var checked = 0
        var raw: [String] = []
        for case let url as URL in files where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            checked += 1
            if text.contains(".sheet(") {
                raw.append(url.lastPathComponent)
            }
        }
        #expect(100 < checked)
        #expect(raw.isEmpty)
    }

    @Test func theWindowPublishesWhereItsSheetsGoAndTheOverlaysFollow() throws {
        let app = try Self.source("network/NetworkApp.swift")
        #expect(app.components(separatedBy: ".publishesSheetPlacement()").count - 1 == 1)
        for path in [
            "network/ContentView.swift",
            "network/iOS/Navigation/MainTabView.swift",
            "network/Shared/Views/ConnectionRegionPicker.swift",
            "network/Shared/Views/ReferralRoyalty/ReferralRoyalty.swift",
        ] {
            #expect(try Self.source(path).contains(".overlayOffTheFold()"), "\(path)")
        }
    }
}
