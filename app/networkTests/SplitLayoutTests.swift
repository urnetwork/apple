//
//  SplitLayoutTests.swift
//  networkTests
//

import CoreGraphics
import Testing
@testable import URnetwork

/**
 * The window rules of the split screens (apple/DUO.md, "Design direction
 * agreed after this research"): compact width keeps the phone layout; a
 * regular-width window stacks the canvas over the statistics under 840 pt and
 * puts them side by side from 840 pt; a partly folded device picks by its
 * posture; a split lands on the fold, else 40/60 side by side and 50/50
 * stacked; the drawer stops at the window and at a tabletop fold; and the
 * canvas gives way in a short window without sliding under the drawer.
 */
struct SplitLayoutTests {

    // iPhone Duo's inner display, at 3x: 669 x 951 pt
    private static let duoPortrait = CGSize(width: 669, height: 951)
    private static let duoLandscape = CGSize(width: 951, height: 669)

    /// A flat hinge: inactive and zero wide.
    private static func flatHinge(x: CGFloat, height: CGFloat) -> WindowFold {
        WindowFold(frame: CGRect(x: x, y: 0, width: 0, height: height), isActive: false)
    }

    // MARK: arrangement

    @Test func compactWidthKeepsThePhoneLayout() {
        #expect(SplitLayout.connectArrangement(isRegularWidth: false, width: 402, fold: nil) == .drawer)
        // a phone in landscape is wide but compact
        #expect(SplitLayout.connectArrangement(isRegularWidth: false, width: 874, fold: nil) == .drawer)
        // half of an unfolded iPhone Duo in Split View, folded in tabletop
        let tabletop = WindowFold(frame: CGRect(x: 0, y: 455, width: 334, height: 41), isActive: true)
        #expect(SplitLayout.connectArrangement(isRegularWidth: false, width: 334, fold: tabletop) == .drawer)
    }

    @Test func regularWidthStacksUnder840AndSplitsSideBySideFrom840() {
        #expect(SplitLayout.connectArrangement(isRegularWidth: true, width: 744, fold: nil) == .stacked)
        #expect(SplitLayout.connectArrangement(isRegularWidth: true, width: 839, fold: nil) == .stacked)
        #expect(SplitLayout.connectArrangement(isRegularWidth: true, width: 840, fold: nil) == .sideBySide)
        #expect(SplitLayout.connectArrangement(isRegularWidth: true, width: 1194, fold: nil) == .sideBySide)
    }

    @Test func unfoldedDuoStacksInPortraitAndSplitsInLandscape() {
        let portrait = SplitLayout.connectArrangement(
            isRegularWidth: true,
            width: Self.duoPortrait.width,
            fold: WindowFold(frame: CGRect(x: 0, y: 475, width: 669, height: 0), isActive: false)
        )
        #expect(portrait == .stacked)

        let landscape = SplitLayout.connectArrangement(
            isRegularWidth: true,
            width: Self.duoLandscape.width,
            fold: Self.flatHinge(x: 475, height: Self.duoLandscape.height)
        )
        #expect(landscape == .sideBySide)
    }

    @Test func aPartlyFoldedDeviceDecidesByItsPosture() {
        // tabletop stacks the panes even in a wide window
        let tabletop = WindowFold(frame: CGRect(x: 0, y: 330, width: 1000, height: 40), isActive: true)
        #expect(SplitLayout.connectArrangement(isRegularWidth: true, width: 1000, fold: tabletop) == .stacked)
        // book posture puts them side by side even under 840 pt
        let book = WindowFold(frame: CGRect(x: 330, y: 0, width: 40, height: 900), isActive: true)
        #expect(SplitLayout.connectArrangement(isRegularWidth: true, width: 700, fold: book) == .sideBySide)
        // flat, the fold does not decide
        let flat = WindowFold(frame: CGRect(x: 0, y: 330, width: 1000, height: 0), isActive: false)
        #expect(SplitLayout.connectArrangement(isRegularWidth: true, width: 1000, fold: flat) == .sideBySide)
    }

    // MARK: panes

    @Test func withoutAFoldSideBySideSplits40And60AndStackedSplitsInHalf() {
        let sideBySide = SplitLayout.panes(size: CGSize(width: 1000, height: 700), sideBySide: true, fold: nil)
        #expect(sideBySide == SplitPanes(firstEnd: 400, secondStart: 400))
        let stacked = SplitLayout.panes(size: CGSize(width: 744, height: 900), sideBySide: false, fold: nil)
        #expect(stacked == SplitPanes(firstEnd: 450, secondStart: 450))
    }

    @Test func aFlatHingeSplitsThePanesAtTheHinge() {
        let panes = SplitLayout.panes(
            size: Self.duoLandscape,
            sideBySide: true,
            fold: Self.flatHinge(x: 475.5, height: Self.duoLandscape.height)
        )
        #expect(panes == SplitPanes(firstEnd: 475.5, secondStart: 475.5))
    }

    @Test func neitherPaneCoversAnActiveFoldOrItsMargins() {
        let book = WindowFold(frame: CGRect(x: 455, y: 0, width: 41, height: 669), isActive: true)
        #expect(
            SplitLayout.panes(size: Self.duoLandscape, sideBySide: true, fold: book)
                == SplitPanes(firstEnd: 455, secondStart: 496)
        )

        // tabletop: the stacked split's edge lands on the fold
        let tabletop = WindowFold(frame: CGRect(x: 0, y: 380, width: 669, height: 40), isActive: true)
        #expect(
            SplitLayout.panes(size: CGSize(width: 669, height: 800), sideBySide: false, fold: tabletop)
                == SplitPanes(firstEnd: 380, secondStart: 420)
        )
    }

    @Test func aFoldAcrossTheSplitOrNearAnEdgeIsNotSplitAt() {
        // a fold that runs along the split, not between the panes
        let tabletop = WindowFold(frame: CGRect(x: 0, y: 330, width: 1000, height: 40), isActive: true)
        #expect(
            SplitLayout.panes(size: CGSize(width: 1000, height: 700), sideBySide: true, fold: tabletop)
                == SplitPanes(firstEnd: 400, secondStart: 400)
        )
        // a fold so close to an edge one pane would be a sliver
        let edge = Self.flatHinge(x: 100, height: 700)
        #expect(
            SplitLayout.panes(size: CGSize(width: 1000, height: 700), sideBySide: true, fold: edge)
                == SplitPanes(firstEnd: 400, secondStart: 400)
        )
    }

    // MARK: the drawer

    @Test func theDrawerIs680WhereItFitsAndCappedByTheWindowElsewhere() {
        // an iPhone 17 Pro in portrait: unchanged
        #expect(SplitLayout.drawerExpandedHeight(screenHeight: 812, fold: nil) == 680)
        // iPhone Duo's outer display and an iPhone SE: the top stays clear
        #expect(SplitLayout.drawerExpandedHeight(screenHeight: 640, fold: nil) == 616)
        #expect(SplitLayout.drawerExpandedHeight(screenHeight: 598, fold: nil) == 574)
        #expect(SplitLayout.drawerExpandedHeight(screenHeight: 10, fold: nil) == 0)
    }

    @Test func inTabletopTheDrawerStopsAtTheFold() {
        let tabletop = WindowFold(frame: CGRect(x: 0, y: 430, width: 334, height: 40), isActive: true)
        #expect(SplitLayout.drawerExpandedHeight(screenHeight: 900, fold: tabletop) == 430)
        // flat, or folded like a book, the fold does not cut the drawer
        var flat = tabletop
        flat.isActive = false
        #expect(SplitLayout.drawerExpandedHeight(screenHeight: 900, fold: flat) == 680)
        let book = WindowFold(frame: CGRect(x: 300, y: 0, width: 40, height: 900), isActive: true)
        #expect(SplitLayout.drawerExpandedHeight(screenHeight: 900, fold: book) == 680)
    }

    // MARK: the canvas

    private static let statusHeight: CGFloat = 20

    /// The block's top and bottom edges in a stack of `height` whose flexible
    /// space splits evenly above and below the block and its spacer.
    private static func blockEdges(_ placement: CanvasPlacement, height: CGFloat) -> (top: CGFloat, bottom: CGFloat) {
        let center = (height - placement.bottomSpacer) / 2
        let block = SplitLayout.canvasBlockHeight(side: placement.canvasSide, statusHeight: statusHeight)
        return (center - block / 2, center + block / 2)
    }

    @Test func aTallPhoneKeepsTodaysCanvas() {
        // iPhone 17 Pro in portrait: 729 pt above the tab bar, the collapsed
        // drawer from 537
        let placement = SplitLayout.drawerCanvasPlacement(height: 729, drawerTop: 537, statusHeight: Self.statusHeight)
        #expect(placement == CanvasPlacement(canvasSide: 256, bottomSpacer: 112))
    }

    @Test func aShorterPhoneLiftsTheFullCanvasClearOfTheDrawer() {
        // iPhone SE: today's layout put the status under the drawer
        let placement = SplitLayout.drawerCanvasPlacement(height: 598, drawerTop: 406, statusHeight: Self.statusHeight)
        #expect(placement.canvasSide == 256)
        let edges = Self.blockEdges(placement, height: 598)
        #expect(edges.bottom == 406 - SplitLayout.drawerCanvasMargin)
        #expect(SplitLayout.drawerCanvasMargin <= edges.top)
    }

    @Test func aShortWindowShrinksTheCanvasBetweenTheTopAndTheDrawer() {
        // a phone in landscape
        let placement = SplitLayout.drawerCanvasPlacement(height: 330, drawerTop: 140, statusHeight: Self.statusHeight)
        #expect(placement.canvasSide < 256)
        #expect(SplitLayout.drawerCanvasMinSide <= placement.canvasSide)
        let edges = Self.blockEdges(placement, height: 330)
        #expect(SplitLayout.drawerCanvasMargin <= edges.top)
        #expect(edges.bottom <= 140 - SplitLayout.drawerCanvasMargin)
    }

    @Test func theCanvasMovesSmoothlyAsTheWindowShortens() {
        // a resize across each boundary moves the block's bottom edge by
        // about the resize, never a jump
        var previous: CGFloat? = nil
        for height in stride(from: CGFloat(800), through: 300, by: -1) {
            let drawerTop = height - 192
            let placement = SplitLayout.drawerCanvasPlacement(height: height, drawerTop: drawerTop, statusHeight: Self.statusHeight)
            let bottom = Self.blockEdges(placement, height: height).bottom
            if let previous {
                #expect(abs(previous - bottom) <= 2)
            }
            previous = bottom
        }
    }

    @Test func aPaneSizesTheCanvasBetweenItsFloorAndCeiling() {
        // a tall pane caps it at 280
        #expect(SplitLayout.paneCanvasSide(height: 700, reservedHeight: 0, statusHeight: Self.statusHeight) == 280)
        // a landscape iPhone's pane fits it to the height
        let side = SplitLayout.paneCanvasSide(height: 300, reservedHeight: 24, statusHeight: Self.statusHeight)
        #expect(160 <= side && side < 280)
        #expect(SplitLayout.canvasBlockHeight(side: side, statusHeight: Self.statusHeight) <= 300 - 24)
        // too short for anything: the floor
        #expect(SplitLayout.paneCanvasSide(height: 80, reservedHeight: 0, statusHeight: Self.statusHeight) == SplitLayout.paneCanvasMinSide)
    }

    @Test func theFittedCanvasFillsTheHeightItWasFittedTo() {
        for height in stride(from: CGFloat(150), through: 420, by: 7) {
            let side = SplitLayout.canvasSide(fitting: height, statusHeight: Self.statusHeight, minimum: 0, maximum: 1000)
            let block = SplitLayout.canvasBlockHeight(side: side, statusHeight: Self.statusHeight)
            #expect(block <= height)
            #expect(height - block < 2)
        }
    }

    // MARK: the auth screens and Account

    @Test func theCarouselSitsBesideTheFormOnlyInAWideRegularWindow() {
        #expect(TabletLayout.showsCarouselBesideForm(isRegularWidth: true, size: CGSize(width: 1194, height: 834)))
        #expect(!TabletLayout.showsCarouselBesideForm(isRegularWidth: true, size: CGSize(width: 834, height: 1194)))
        // a phone in landscape, or a narrow window on a landscape iPad
        #expect(!TabletLayout.showsCarouselBesideForm(isRegularWidth: false, size: CGSize(width: 874, height: 402)))
        #expect(!TabletLayout.showsCarouselBesideForm(isRegularWidth: false, size: CGSize(width: 507, height: 834)))
    }

    @Test func accountKeepsItsScreenAcrossTheListDetailSwitch() {
        let model = AccountNavStackView.ViewModel()

        // the phone: Settings, then Licenses over it
        model.navigate(.settings)
        model.navigate(.licenses)

        // unfolded: Settings is chosen beside the list, Licenses over it
        #expect(model.selection == .settings)
        #expect(model.detailPath == [.licenses])

        // back on the right pops Licenses, and the phone sees the same
        model.detailPath = []
        #expect(model.navigationPath == [.settings])

        // a row of the list replaces the chosen screen and what it opened
        model.navigate(.licenses)
        model.select(.profile)
        #expect(model.navigationPath == [.profile])
        #expect(model.detailPath.isEmpty)
    }
}
