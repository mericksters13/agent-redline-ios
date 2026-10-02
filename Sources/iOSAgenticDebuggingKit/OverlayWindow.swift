#if AGENTIC_DEBUGGING && canImport(UIKit)
import SwiftUI
import UIKit

/// The debugger's own window, above the app. Touches pass through to the app
/// except while the debugger is active or on the idle draft capsule.
final class OverlayWindow: UIWindow {
    var claimsAllTouches = false
    var touchableRect: CGRect?
    var onLayout: ((OverlayWindow) -> Void)?
    /// Called with the timestamp of every touch on the screen, including the ones
    /// passed through to the app. This window is on top, so it is asked first.
    var onTouch: ((TimeInterval) -> Void)?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if let event, event.type == .touches {
            onTouch?(event.timestamp)
        }
        guard claimsAllTouches || touchableRect?.contains(point) == true else { return nil }
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
