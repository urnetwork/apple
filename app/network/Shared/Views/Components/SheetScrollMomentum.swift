//
//  SheetScrollMomentum.swift
//  URnetwork
//

import SwiftUI

#if os(iOS)
import UIKit

/**
 * Holds a weak reference to the UIScrollView behind a SwiftUI ScrollView, so
 * a gesture that ends outside the scroll view can drive its content offset.
 * Filled in by `ScrollViewFinder` placed inside the scroll view's content.
 */
final class SheetScrollViewRef {
    weak var scrollView: UIScrollView?
}

/**
 * Place inside a ScrollView's content (e.g. as the background of its first
 * child). When it joins the window it walks up to the nearest UIScrollView
 * and records it in `ref`.
 */
struct ScrollViewFinder: UIViewRepresentable {

    let ref: SheetScrollViewRef

    func makeUIView(context: Context) -> FinderView {
        let view = FinderView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.ref = ref
        return view
    }

    func updateUIView(_ uiView: FinderView, context: Context) {
        uiView.ref = ref
        uiView.find()
    }

    final class FinderView: UIView {

        var ref: SheetScrollViewRef?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            find()
        }

        func find() {
            guard window != nil else { return }
            var view: UIView? = superview
            while let current = view {
                if let scrollView = current as? UIScrollView {
                    ref?.scrollView = scrollView
                    return
                }
                view = current.superview
            }
        }

    }

}

/**
 * Carries a fling's remaining momentum into a scroll view by stepping
 * UIScrollView's own deceleration on a display link: every millisecond the
 * speed is multiplied by the deceleration rate, and the content offset moves
 * by the distance covered. Stops at the far end, when the speed is spent, or
 * as soon as the user touches the scroll view again.
 */
final class ScrollMomentumDriver {

    private weak var scrollView: UIScrollView?
    private var displayLink: CADisplayLink?
    private var speed: CGFloat = 0
    private var maxOffset: CGFloat = 0
    private var decelerationRate: CGFloat = UIScrollView.DecelerationRate.normal.rawValue
    private var lastTimestamp: CFTimeInterval = 0
    private var startAt: CFTimeInterval = 0

    /// Starts scrolling `scrollView` downward at `speed` points per second
    /// after `delay` seconds, never past `maxOffset`. The delay lets the
    /// content pick up a fling exactly where the fling's own clock says the
    /// sheet's travel ends, so the motion reads as one scroll.
    func start(scrollView: UIScrollView, speed: CGFloat, maxOffset: CGFloat, decelerationRate: CGFloat, delay: TimeInterval = 0) {
        stop()
        guard speed > 0, maxOffset > scrollView.contentOffset.y else { return }
        self.scrollView = scrollView
        self.speed = speed
        self.maxOffset = maxOffset
        self.decelerationRate = decelerationRate
        lastTimestamp = 0
        startAt = CACurrentMediaTime() + max(0, delay)
        let link = CADisplayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        scrollView = nil
        speed = 0
    }

    @objc private func step(_ link: CADisplayLink) {
        guard let scrollView, !scrollView.isTracking, !scrollView.isDragging else {
            stop()
            return
        }
        if link.timestamp < startAt {
            return
        }
        if lastTimestamp == 0 {
            lastTimestamp = link.timestamp
            return
        }
        let dt = link.timestamp - lastTimestamp
        lastTimestamp = link.timestamp
        let milliseconds = CGFloat(dt * 1000)
        // distance covered while the speed decays over this frame
        let decay = pow(decelerationRate, milliseconds)
        let distance = speed / 1000 * decelerationRate * (1 - decay) / (1 - decelerationRate)
        speed *= decay
        let target = min(maxOffset, scrollView.contentOffset.y + distance)
        scrollView.contentOffset = CGPoint(x: scrollView.contentOffset.x, y: target)
        if target >= maxOffset || speed < 1 {
            stop()
        }
    }

}

#endif
