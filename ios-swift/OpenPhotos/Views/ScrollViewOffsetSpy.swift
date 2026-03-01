import SwiftUI
import UIKit

/// ScrollViewOffsetSpy attaches to the nearest UIScrollView (ancestor) and
/// observes its `contentOffset` via KVO. It calls `onChange` with the current
/// offset on every change. This is useful when GeometryReader-based offset
/// tracking is unreliable.
struct ScrollViewOffsetSpy: UIViewRepresentable {
    let onChange: (CGPoint) -> Void

    func makeUIView(context: Context) -> SpyView {
        let v = SpyView()
        v.onChange = onChange
        return v
    }

    func updateUIView(_ uiView: SpyView, context: Context) {
        // no-op
    }

    final class SpyView: UIView {
        var onChange: ((CGPoint) -> Void)?
        private weak var scrollView: UIScrollView?
        private var obs: NSKeyValueObservation?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            // Defer so hierarchy is established
            DispatchQueue.main.async { [weak self] in self?.attachIfNeeded() }
        }

        deinit { obs?.invalidate() }

        private func attachIfNeeded() {
            guard scrollView == nil else { return }
            if let sv = findScrollView(start: self) {
                scrollView = sv
                obs = sv.observe(\.contentOffset, options: [.initial, .new]) { [weak self] _, _ in
                    guard let self = self, let sv = self.scrollView else { return }
                    self.onChange?(sv.contentOffset)
                }
                // Debug print removed
            }
        }

        private func findScrollView(start: UIView?) -> UIScrollView? {
            var node = start
            var hops = 0
            while let cur = node, hops < 50 {
                if let sv = cur as? UIScrollView { return sv }
                node = cur.superview
                hops += 1
            }
            return nil
        }
    }
}
