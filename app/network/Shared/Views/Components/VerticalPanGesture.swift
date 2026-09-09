//
//  VerticalPanGesture.swift
//  URnetwork
//

import SwiftUI

#if os(iOS)
import UIKit

extension View {

    /**
     * Attaches a UIKit pan gesture recognizer covering this view's bounds that
     * only begins for predominantly vertical pans. Taps and horizontal slides
     * pass through to the controls under the touch. Once the pan begins, the
     * in-flight touches are cancelled (like a scroll view), so a drag that
     * starts on a control moves the view without triggering the control.
     *
     * Scroll views under this view defer to the pan: they wait for it to
     * decline before scrolling, so `shouldBegin` decides whether a drag moves
     * this view or scrolls the content. `shouldBegin` receives the vertical
     * translation (negative when dragging up) and the touch location in this
     * view's bounds; when nil, all predominantly vertical pans begin.
     *
     * `onChanged` and `onEnded` receive the vertical translation in points,
     * negative when dragging up. `onEnded` also receives the release velocity
     * in points per second with the same sign, so a flick can be told apart
     * from a slow release and its momentum carried on.
     */
    func verticalPanGesture(
        onChanged: @escaping (CGFloat) -> Void,
        onEnded: @escaping (CGFloat, CGFloat) -> Void,
        shouldBegin: ((CGFloat, CGPoint) -> Bool)? = nil
    ) -> some View {
        background(VerticalPanGestureView(onChanged: onChanged, onEnded: onEnded, shouldBegin: shouldBegin))
    }

}

private struct VerticalPanGestureView: UIViewRepresentable {

    let onChanged: (CGFloat) -> Void
    let onEnded: (CGFloat, CGFloat) -> Void
    let shouldBegin: ((CGFloat, CGPoint) -> Bool)?

    func makeCoordinator() -> Coordinator {
        Coordinator(onChanged: onChanged, onEnded: onEnded, shouldBegin: shouldBegin)
    }

    func makeUIView(context: Context) -> MarkerView {
        let view = MarkerView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ uiView: MarkerView, context: Context) {
        context.coordinator.onChanged = onChanged
        context.coordinator.onEnded = onEnded
        context.coordinator.shouldBegin = shouldBegin
    }

    static func dismantleUIView(_ uiView: MarkerView, coordinator: Coordinator) {
        uiView.detachPan()
    }

    class Coordinator: NSObject, UIGestureRecognizerDelegate {

        var onChanged: (CGFloat) -> Void
        var onEnded: (CGFloat, CGFloat) -> Void
        var shouldBegin: ((CGFloat, CGPoint) -> Bool)?
        weak var markerView: UIView?

        init(
            onChanged: @escaping (CGFloat) -> Void,
            onEnded: @escaping (CGFloat, CGFloat) -> Void,
            shouldBegin: ((CGFloat, CGPoint) -> Bool)?
        ) {
            self.onChanged = onChanged
            self.onEnded = onEnded
            self.shouldBegin = shouldBegin
        }

        @objc func handlePan(_ pan: UIPanGestureRecognizer) {
            guard let view = pan.view else { return }
            let translation = pan.translation(in: view).y
            switch pan.state {
            case .changed:
                onChanged(translation)
            case .ended:
                onEnded(translation, pan.velocity(in: view).y)
            case .cancelled, .failed:
                onEnded(translation, 0)
            default:
                break
            }
        }

        /**
         * Only begin for predominantly vertical movement, so horizontal slides
         * on controls (toggle knobs, segmented pickers) keep working. The
         * `shouldBegin` policy then decides between moving the view and
         * letting the content scroll.
         */
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer,
                  let view = pan.view else {
                return false
            }
            let translation = pan.translation(in: view)
            guard abs(translation.y) > abs(translation.x) else {
                return false
            }
            if let shouldBegin, let markerView {
                let location = pan.location(in: markerView)
                return shouldBegin(translation.y, location)
            }
            return true
        }

        /**
         * The recognizer is attached to an ancestor that covers the whole
         * screen, so only accept touches that land within the marker view's
         * bounds (the view this modifier is applied to).
         */
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let markerView, markerView.window != nil else {
                return false
            }
            return markerView.bounds.contains(touch.location(in: markerView))
        }

        /**
         * Scroll pans over this view wait for this recognizer to decline,
         * so a drag at the scroll boundary can move the view instead of
         * rubber-banding the content.
         */
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            return otherGestureRecognizer is UIPanGestureRecognizer && otherGestureRecognizer.view is UIScrollView
        }

    }

    /**
     * Passive view used to track the target area. SwiftUI draws most content
     * into a shared hosting view, so a recognizer attached to this view alone
     * would never receive touches over sibling content. Instead the recognizer
     * is attached to the farthest ancestor below the window, which is in the
     * hit-test chain of every view on this screen but not of presented sheets.
     */
    class MarkerView: UIView {

        var coordinator: Coordinator?
        private var pan: UIPanGestureRecognizer?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            // re-attach on every move so the recognizer follows hierarchy
            // changes, e.g. switching tabs or full screen covers
            detachPan()
            if window != nil {
                attachPan()
            }
        }

        private func attachPan() {
            guard let coordinator else { return }
            var target: UIView = self
            while let superview = target.superview, !(superview is UIWindow) {
                target = superview
            }
            let pan = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.handlePan(_:)))
            pan.maximumNumberOfTouches = 1
            pan.delegate = coordinator
            target.addGestureRecognizer(pan)
            self.pan = pan
            coordinator.markerView = self
        }

        func detachPan() {
            if let pan {
                pan.view?.removeGestureRecognizer(pan)
                self.pan = nil
            }
        }

    }

}

#endif
