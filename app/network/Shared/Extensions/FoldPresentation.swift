//
//  FoldPresentation.swift
//  URnetwork
//
//  Keeps sheets and the window-wide overlays off the fold of a partly folded
//  iPhone Duo (apple/DUO.md item 11), by SplitLayout's rules
//  (presentationPane, sheetPlacement, overlayFrame):
//  - every sheet presents through sheetOffTheFold. While the fold divides the
//    window like a book, the system places the sheet on its pane's side
//    (presentationPlacement, iOS 27) no wider than the pane
//    (presentationSizing). Otherwise nothing is applied, so iPhone, iPad, the
//    Mac and a flat or closed iPhone Duo present the sheet as they always have.
//  - an overlay as wide as the window keeps to the same pane
//    (overlayOffTheFold).
//  The system itself moves alerts, confirmation dialogs, menus and popovers
//  around the fold, and a full-screen cover is the whole window, so those
//  present as before.
//

import SwiftUI

private struct SheetPlacementKey: EnvironmentKey {
    static let defaultValue: SheetPlacement? = nil
}

extension EnvironmentValues {

    /// Where sheets go while a fold divides the window like a book,
    /// published by the window's root (publishesSheetPlacement); nil
    /// otherwise. A sheet reads the window's value and never its own
    /// geometry: a sheet already off the fold no longer sees it.
    var sheetPlacement: SheetPlacement? {
        get { self[SheetPlacementKey.self] }
        set { self[SheetPlacementKey.self] = newValue }
    }
}

extension View {

    /// Presents a sheet as `sheet(isPresented:onDismiss:content:)` does,
    /// kept off a fold that divides the window (sheetPlacement).
    func sheetOffTheFold<Content: View>(
        isPresented: Binding<Bool>,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        sheet(isPresented: isPresented, onDismiss: onDismiss) {
            content()
                .modifier(SheetOffTheFold())
        }
    }

    /// Presents a sheet as `sheet(item:onDismiss:content:)` does, kept off a
    /// fold that divides the window (sheetPlacement).
    func sheetOffTheFold<Item: Identifiable, Content: View>(
        item: Binding<Item?>,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        sheet(item: item, onDismiss: onDismiss) { item in
            content(item)
                .modifier(SheetOffTheFold())
        }
    }

    /// Publishes where the window's sheets go to everything under it, the
    /// sheets it presents included. Apply once, at the root of the iOS
    /// window.
    func publishesSheetPlacement() -> some View {
        modifier(SheetPlacementPublisher())
    }

    /// Keeps an overlay as wide as the window to one pane while a fold
    /// divides the window like a book (SplitLayout.overlayFrame). Apply to a
    /// view that fills the window; without a fold its layout is unchanged.
    func overlayOffTheFold() -> some View {
        modifier(OverlayOffTheFold())
    }
}

/// The sheet's side and width while the fold divides the window. The
/// presentation modifiers sit on a clear background: they reach the sheet
/// from anywhere in its content, and a fold that comes or goes changes only
/// that background, so the sheet's own content and its state stay.
private struct SheetOffTheFold: ViewModifier {

    @Environment(\.sheetPlacement) private var placement

    func body(content: Content) -> some View {
        content
            .background {
                #if os(iOS)
                // presentationPlacement is iOS 27.0; a placement is published
                // only where the window has a fold, which is iOS 27.1
                if #available(iOS 27.0, *) {
                    if let placement {
                        Color.clear
                            .presentationPlacement(placement.side == .leading ? .leading : .trailing)
                            .presentationSizing(FoldPaneSizing(maxWidth: placement.maxWidth))
                    }
                }
                #endif
            }
    }
}

#if os(iOS)
/// The size the system gives a sheet, no wider than its pane.
@available(iOS 18.0, *)
private struct FoldPaneSizing: PresentationSizing {

    let maxWidth: CGFloat

    func proposedSize(for root: PresentationSizingRoot, context: PresentationSizingContext) -> ProposedViewSize {
        let automatic: AutomaticPresentationSizing = .automatic
        var size = automatic.proposedSize(for: root, context: context)
        size.width = min(size.width ?? maxWidth, maxWidth)
        return size
    }
}
#endif

/// Measures the window it is applied to, and publishes where its sheets go.
private struct SheetPlacementPublisher: ViewModifier {

    @State private var placement: SheetPlacement? = nil

    func body(content: Content) -> some View {
        content
            .environment(\.sheetPlacement, placement)
            #if os(iOS)
            // the window's own space, inside its safe area: a sheet clears
            // a vertical bar as well as the fold
            .onGeometryChange(for: SheetPlacement?.self) { proxy in
                SplitLayout.sheetPlacement(size: proxy.size, fold: proxy.windowFold)
            } action: { newValue in
                placement = newValue
            }
            #endif
    }
}

/// Insets an overlay as wide as the window to its pane while the fold
/// divides the window like a book. Only the insets change, never the view's
/// structure, so a fold that comes or goes keeps the overlay's state; without
/// a fold they are zero.
private struct OverlayOffTheFold: ViewModifier {

    @State private var insets = EdgeInsets()

    func body(content: Content) -> some View {
        content
            .padding(.leading, insets.leading)
            .padding(.trailing, insets.trailing)
            #if os(iOS)
            // measured outside the padding: the overlay's whole frame
            .onGeometryChange(for: EdgeInsets.self) { proxy in
                let pane = SplitLayout.overlayFrame(size: proxy.size, fold: proxy.windowFold)
                return EdgeInsets(
                    top: 0,
                    leading: pane.minX,
                    bottom: 0,
                    trailing: proxy.size.width - pane.maxX
                )
            } action: { newValue in
                insets = newValue
            }
            #endif
    }
}
