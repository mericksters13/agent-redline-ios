#if AGENTIC_DEBUGGING && canImport(UIKit)
import SwiftUI
import UIKit

/// The debugger's own window, above the app. Touches pass through to the app
/// except while the debugger is active or on the floating button. Screenshots are
/// drawn from the app's windows only, so nothing in this window ever appears in them.
final class OverlayWindow: UIWindow {
    var claimsAllTouches = false
    /// The floating button's frame. Only the round button inside it takes touches, so a
    /// tap in a corner of the frame reaches the app underneath.
    var buttonFrame: CGRect?
    var onLayout: ((OverlayWindow) -> Void)?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard claimsAllTouches || buttonFrame.map({ FloatingButtonPlacement.buttonContains(point, frame: $0) }) == true else { return nil }
        return super.hitTest(point, with: event)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?(self)
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        onLayout?(self)
    }
}

/// Finds the window scene the app's root view lives in and installs the debugger there.
struct SceneHook: UIViewRepresentable {
    func makeUIView(context: Context) -> HookView { HookView() }
    func updateUIView(_ uiView: HookView, context: Context) {}

    final class HookView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let window, !(window is OverlayWindow), let scene = window.windowScene else { return }
            DebugSession.shared.install(in: scene)
        }
    }
}
#endif
