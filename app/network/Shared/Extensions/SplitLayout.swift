//
//  SplitLayout.swift
//  URnetwork
//
//  The window rules of the split screens (apple/DUO.md, "Design direction
//  agreed after this research"): which arrangement the connect screen takes
//  for the window it gets, where a split puts its two panes (at the fold of a
//  foldable, else 40/60 side by side and 50/50 stacked), how far the connect
//  canvas and the phone drawer give way in a short window, and which pane a
//  sheet or a window-wide overlay moves into while the device is partly
//  folded (DUO.md item 11). Pure geometry, so every rule is testable without
//  a window.
//

import CoreGraphics

/// The fold that divides a foldable's window: the division reserved region
/// in the container's coordinates (iPhone Duo, iOS 27.1). Flat, the fold is
/// inactive and zero wide at the hinge; partly folded it is active, and its
/// frame includes the margins interactive content keeps clear of.
struct WindowFold: Equatable {
    var frame: CGRect
    var isActive: Bool

    /// A fold that runs top to bottom divides a left half from a right half
    /// (book posture); one that runs across divides a top half from a bottom
    /// half (tabletop).
    var isVertical: Bool {
        frame.width < frame.height
    }
}

/// How the iOS connect screen lays out its canvas and its drawer.
enum ConnectArrangement: Equatable {
    /// compact width: the phone layout, the canvas above the bottom drawer
    case drawer
    /// regular width under 840 pt, or folded in tabletop: the canvas above,
    /// the statistics and the action buttons below
    case stacked
    /// regular width from 840 pt, or folded like a book: the statistics pane
    /// beside the connect pane
    case sideBySide
}

/// Where a split puts its two panes along its axis. The first pane (leading
/// side by side, top stacked) ends at `firstEnd` and the second starts at
/// `secondStart`; they differ only around an active fold, whose margins
/// neither pane covers.
struct SplitPanes: Equatable {
    var firstEnd: CGFloat
    var secondStart: CGFloat
}

/// Where a layout puts the connect canvas: its side, and the space under the
/// canvas block, which with the flexible space around the block places it
/// (above the drawer in the phone layout; centered in a pane, with none).
struct CanvasPlacement: Equatable {
    var canvasSide: CGFloat
    var bottomSpacer: CGFloat
}

/// A side of a fold that runs top to bottom through the window, in the
/// layout direction (leading is the right side in a right-to-left language).
enum FoldSide: Equatable {
    case leading
    case trailing
}

/// The pane a presentation that would cross the fold moves into: one side of
/// it, and that side's frame in the window's coordinates, the fold and its
/// margins left out.
struct FoldPresentationPane: Equatable {
    var side: FoldSide
    var frame: CGRect
}

/// Where a sheet goes while the fold divides the window like a book: the side
/// the system places it on (`presentationPlacement`), and the widest it can
/// be there without reaching the fold.
struct SheetPlacement: Equatable {
    var side: FoldSide
    var maxWidth: CGFloat
}

enum SplitLayout {

    /// The narrowest regular-width window that puts two panes side by side
    /// (the expanded width class); narrower ones stack them.
    static let sideBySideMinWidth: CGFloat = 840

    /// Without a fold to split at, side by side panes split 40/60, the
    /// statistics or list pane first, and stacked panes 50/50.
    static let sideBySideFraction: CGFloat = 0.4
    static let stackedFraction: CGFloat = 0.5

    /// A fold this close to an edge is not split at: one pane would be
    /// narrower than this fraction of the window.
    static let minimumPaneFraction: CGFloat = 0.25

    /// The connect screen's arrangement. A partly folded device decides it
    /// by its posture, so the split lands on the fold; otherwise the width
    /// does.
    static func connectArrangement(
        isRegularWidth: Bool,
        width: CGFloat,
        fold: WindowFold?
    ) -> ConnectArrangement {
        guard isRegularWidth else {
            return .drawer
        }
        if let fold, fold.isActive {
            return fold.isVertical ? .sideBySide : .stacked
        }
        return sideBySideMinWidth <= width ? .sideBySide : .stacked
    }

    /// The two panes of a split across `size`: side by side along its width,
    /// else stacked along its height. A fold that runs between them sets the
    /// split, flat or folded, unless it lies too close to an edge.
    static func panes(size: CGSize, sideBySide: Bool, fold: WindowFold?) -> SplitPanes {
        let length = sideBySide ? size.width : size.height
        if let fold, fold.isVertical == sideBySide {
            let start = sideBySide ? fold.frame.minX : fold.frame.minY
            let end = sideBySide ? fold.frame.maxX : fold.frame.maxY
            let margin = length * minimumPaneFraction
            if margin <= start && end <= length - margin {
                return SplitPanes(firstEnd: start, secondStart: end)
            }
        }
        let fraction = sideBySide ? sideBySideFraction : stackedFraction
        let split = (length * fraction).rounded()
        return SplitPanes(firstEnd: split, secondStart: split)
    }

    // MARK: the phone drawer

    /// The phone drawer's expanded height at most.
    static let drawerMaxHeight: CGFloat = 680

    /// The clear space an expanded drawer leaves above it, under the top of
    /// the window.
    static let drawerTopMargin: CGFloat = 24

    /// The phone drawer's expanded height: 680 pt, capped so its top edge
    /// stays a margin below the top of the window, and, on a device folded
    /// in tabletop, so the drawer stops at the fold. `screenHeight` runs to
    /// the drawer's bottom edge, behind the tab bar.
    static func drawerExpandedHeight(screenHeight: CGFloat, fold: WindowFold?) -> CGFloat {
        var height = min(drawerMaxHeight, screenHeight - drawerTopMargin)
        if let fold, fold.isActive, !fold.isVertical {
            height = min(height, screenHeight - fold.frame.maxY)
        }
        return max(0, height)
    }

    // MARK: the connect canvas

    /// The connect canvas's side in the phone layout, and its range in a pane.
    static let canvasFullSide: CGFloat = 256
    static let paneCanvasMaxSide: CGFloat = 280
    /// The floors a short window shrinks the canvas to before its block
    /// overflows; the canvas shrinks only when the room runs out.
    static let drawerCanvasMinSide: CGFloat = 48
    static let paneCanvasMinSide: CGFloat = 64

    /// The canvas block (ConnectButtonView): its padding, and the gaps above
    /// and below the status line at full size, which scale with the canvas.
    static let canvasBlockPadding: CGFloat = 16
    static let canvasStatusGap: CGFloat = 32
    static let canvasStatusBottomGap: CGFloat = 16

    /// The space the phone layout keeps under the canvas block when the
    /// window is tall enough (the drawer's collapsed peek sits there).
    static let drawerCanvasBottomSpacer: CGFloat = 112

    /// The devices online line under the status of the stacked split.
    static let peersLineHeight: CGFloat = 24

    /// The location picker as a popover at regular width: no wider than its
    /// pane holds, and no taller than the window.
    static let locationPopoverMaxWidth: CGFloat = 400
    static let locationPopoverMaxHeight: CGFloat = 600

    /// What a short phone window keeps clear between the canvas block and
    /// the top of the window (the slow internet pill) or the drawer.
    static let drawerCanvasMargin: CGFloat = 8

    /// The canvas block's height for a canvas of `side`.
    static func canvasBlockHeight(side: CGFloat, statusHeight: CGFloat) -> CGFloat {
        let scale = side / canvasFullSide
        return 2 * canvasBlockPadding + side + (canvasStatusGap + canvasStatusBottomGap) * scale + statusHeight
    }

    /// The largest canvas whose block fits in `height`, within the range.
    static func canvasSide(
        fitting height: CGFloat,
        statusHeight: CGFloat,
        minimum: CGFloat,
        maximum: CGFloat
    ) -> CGFloat {
        let perPoint = 1 + (canvasStatusGap + canvasStatusBottomGap) / canvasFullSide
        let side = ((height - 2 * canvasBlockPadding - statusHeight) / perPoint).rounded(.down)
        return min(maximum, max(minimum, side))
    }

    /// The canvas in a pane of `height`, the pane's other content (the
    /// devices online line) taking `reservedHeight` of it.
    static func paneCanvasSide(height: CGFloat, reservedHeight: CGFloat, statusHeight: CGFloat) -> CGFloat {
        canvasSide(
            fitting: height - reservedHeight,
            statusHeight: statusHeight,
            minimum: paneCanvasMinSide,
            maximum: paneCanvasMaxSide
        )
    }

    /// The phone layout's canvas in a window of `height` whose collapsed
    /// drawer starts at `drawerTop`. A tall window keeps today's layout: the
    /// full canvas centered above the 112 pt spacer. Shorter, the block moves
    /// up just enough to clear the drawer, then shrinks to fit between the
    /// top of the window and the drawer, so it never slides under either.
    static func drawerCanvasPlacement(
        height: CGFloat,
        drawerTop: CGFloat,
        statusHeight: CGFloat
    ) -> CanvasPlacement {
        let top = drawerCanvasMargin
        let bottom = drawerTop - drawerCanvasMargin
        let fullBlock = canvasBlockHeight(side: canvasFullSide, statusHeight: statusHeight)

        // the block's center for a bottom spacer, in a stack whose flexible
        // space splits evenly above and below: (height - spacer) / 2
        let todayCenter = (height - drawerCanvasBottomSpacer) / 2
        if top <= todayCenter - fullBlock / 2 && todayCenter + fullBlock / 2 <= bottom {
            return CanvasPlacement(canvasSide: canvasFullSide, bottomSpacer: drawerCanvasBottomSpacer)
        }

        if fullBlock <= bottom - top {
            // the full block, resting on the drawer
            let center = bottom - fullBlock / 2
            return CanvasPlacement(
                canvasSide: canvasFullSide,
                bottomSpacer: max(0, height - 2 * center)
            )
        }

        // the canvas shrinks to the space between the top and the drawer
        let side = canvasSide(
            fitting: bottom - top,
            statusHeight: statusHeight,
            minimum: drawerCanvasMinSide,
            maximum: canvasFullSide
        )
        return CanvasPlacement(
            canvasSide: side,
            bottomSpacer: max(0, height - top - bottom)
        )
    }
}

// MARK: presentations off the fold

extension SplitLayout {

    /// What a sheet moved into a pane keeps clear on each side of it, from
    /// the window's edge and from the fold's own margins: room for the
    /// margins the system places a sheet within.
    static let sheetPaneMargin: CGFloat = 16

    /// The pane a sheet, or an overlay as wide as the window, moves into
    /// while the device is partly folded like a book, the fold running top
    /// to bottom between two panes: the trailing pane, the side the system
    /// moves its own alerts to in that pose, unless the fold leaves it
    /// narrower than a pane can be, then the leading one.
    ///
    /// Nil leaves a presentation where it is today:
    /// - no fold: iPhone, iPad, the Mac, a closed iPhone Duo;
    /// - a flat hinge: inactive, nothing to straddle. The system centers
    ///   sheets on the open inner display, and they move when it folds, as
    ///   the system's alerts do;
    /// - a fold across the window (tabletop): a sheet has no vertical
    ///   placement, so the system places it, and the window-wide overlays
    ///   already sit at the top or the bottom edge, each in one pane;
    /// - a fold outside the window, or one that leaves no pane wide enough.
    static func presentationPane(size: CGSize, fold: WindowFold?) -> FoldPresentationPane? {
        guard let fold, fold.isActive, fold.isVertical,
              0 < size.width, fold.frame.minX < size.width, 0 < fold.frame.maxX else {
            return nil
        }
        let minimumWidth = size.width * minimumPaneFraction
        let trailingWidth = size.width - fold.frame.maxX
        if minimumWidth <= trailingWidth {
            return FoldPresentationPane(
                side: .trailing,
                frame: CGRect(x: fold.frame.maxX, y: 0, width: trailingWidth, height: size.height)
            )
        }
        let leadingWidth = fold.frame.minX
        if minimumWidth <= leadingWidth {
            return FoldPresentationPane(
                side: .leading,
                frame: CGRect(x: 0, y: 0, width: leadingWidth, height: size.height)
            )
        }
        return nil
    }

    /// Where a sheet goes while the fold divides the window like a book: its
    /// pane's side, at most the pane's width less a margin on each side. Nil
    /// leaves the sheet where the system puts it today.
    static func sheetPlacement(size: CGSize, fold: WindowFold?) -> SheetPlacement? {
        guard let pane = presentationPane(size: size, fold: fold) else {
            return nil
        }
        return SheetPlacement(
            side: pane.side,
            maxWidth: max(0, pane.frame.width - 2 * sheetPaneMargin)
        )
    }

    /// The frame an overlay as wide as the window keeps (the snackbar, the
    /// can't-reach banner, the referral celebration's column): its pane
    /// while the fold divides the window like a book, else the whole window.
    static func overlayFrame(size: CGSize, fold: WindowFold?) -> CGRect {
        presentationPane(size: size, fold: fold)?.frame ?? CGRect(origin: .zero, size: size)
    }
}
