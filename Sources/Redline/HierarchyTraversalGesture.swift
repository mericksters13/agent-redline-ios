#if REDLINE && canImport(UIKit)
import SwiftUI
import UIKit

/// A held drag owns traversal; movement before the hold remains a normal scroll.
struct HierarchyTraversalGesture: UIGestureRecognizerRepresentable {
    let changed: (CGPoint?) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let recognizer = UILongPressGestureRecognizer()
        recognizer.minimumPressDuration = 0.2
        recognizer.delegate = context.coordinator
        return recognizer
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            // Buttons can track a press, while a recognized hold owns scrolling pans.
            !(otherGestureRecognizer is UIPanGestureRecognizer && otherGestureRecognizer.view is UIScrollView)
        }
    }

    func handleUIGestureRecognizerAction(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        switch recognizer.state {
        case .began, .changed:
            changed(context.converter.location(in: .global))
        case .ended:
            changed(context.converter.location(in: .global))
            changed(nil)
        case .cancelled, .failed:
            changed(nil)
        default: break
        }
    }
}
#endif
