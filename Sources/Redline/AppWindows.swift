#if REDLINE && canImport(UIKit)
import UIKit

/// The app's own windows, without Redline's: which ones are showing, a picture of them, and
/// their scroll views.
@MainActor
enum AppWindows {
    /// The app's visible windows in `scene`, bottom to top, without Redline's.
    static func all(in scene: UIWindowScene?) -> [UIWindow] {
        guard let scene else { return [] }
        return scene.windows
            .filter {
                !($0 is OverlayWindow) && !$0.isHidden && !String(describing: type(of: $0)).contains("TextEffects")
            }
            .sorted { $0.windowLevel < $1.windowLevel }
    }

    /// Every scroll view in `windows`.
    static func scrollViews(in windows: [UIWindow]) -> [UIScrollView] {
        var result: [UIScrollView] = []
        func visit(_ view: UIView) {
            if let scrollView = view as? UIScrollView { result.append(scrollView) }
            for subview in view.subviews { visit(subview) }
        }
        for window in windows { visit(window) }
        return result
    }

    /// Stops a scroll the user started that is still moving, at a valid resting offset.
    static func stopScrolling(_ scrollViews: [UIScrollView]) {
        for scrollView in scrollViews where scrollView.isDecelerating || scrollView.isDragging {
            let inset = scrollView.adjustedContentInset
            let offset = scrollView.contentOffset
            let maxX = max(-inset.left, scrollView.contentSize.width - scrollView.bounds.width + inset.right)
            let maxY = max(-inset.top, scrollView.contentSize.height - scrollView.bounds.height + inset.bottom)
            scrollView.setContentOffset(
                CGPoint(
                    x: min(max(offset.x, -inset.left), maxX),
                    y: min(max(offset.y, -inset.top), maxY)
                ),
                animated: false
            )
        }
    }

    /// Where each scroll view's content is drawn right now.
    ///
    /// A scroll the app animates itself, through `setContentOffset(_:animated:)`,
    /// `scrollRectToVisible(_:animated:)` or an animation block, is neither dragging nor
    /// decelerating, so motion shows only as this changing from one frame to the next.
    static func scrollPositions(of scrollViews: [UIScrollView]) -> [CGPoint] {
        scrollViews.map { $0.layer.presentation()?.bounds.origin ?? $0.contentOffset }
    }

    /// Pixels per point in every screenshot, whatever the screen size, so a saved one can
    /// be cropped around its element's frame after the screen has rotated.
    static let screenshotScale: CGFloat = 2

    /// A picture of the app's windows, without Redline's own window.
    static func screenshot(of windows: [UIWindow], bounds: CGRect) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = screenshotScale
        format.opaque = true
        return UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in
            for window in windows {
                window.drawHierarchy(in: window.frame, afterScreenUpdates: false)
            }
        }
    }

    /// The screen's main vertical scroll view, and how far it's scrolled: the largest one
    /// that scrolls vertically and covers a good part of the screen.
    static func mainScrollState(under roots: [UIView], screenBounds: CGRect) -> ScrollState? {
        var best: (view: UIScrollView, frame: CGRect, area: CGFloat)?
        func visit(_ view: UIView) {
            guard !view.isHidden, view.alpha > 0.01 else { return }
            if let scrollView = view as? UIScrollView, !(view is UITextView) {
                let frame = scrollView.convert(scrollView.bounds, to: nil)
                let visible = frame.intersection(screenBounds)
                let inset = scrollView.adjustedContentInset
                let scrollsVertically =
                    scrollView.contentSize.height > scrollView.bounds.height - inset.top - inset.bottom + 1
                let area = visible.isNull ? 0 : visible.width * visible.height
                if scrollsVertically, area > (best?.area ?? 0) { best = (scrollView, frame, area) }
            }
            for subview in view.subviews { visit(subview) }
        }
        for root in roots { visit(root) }
        guard let best, best.area > screenBounds.width * screenBounds.height * 0.3 else { return nil }
        let inset = best.view.adjustedContentInset
        return ScrollState(
            frame: best.frame,
            offsetY: best.view.contentOffset.y,
            insetTop: inset.top,
            insetBottom: inset.bottom,
            contentHeight: best.view.contentSize.height
        )
    }
}
#endif
