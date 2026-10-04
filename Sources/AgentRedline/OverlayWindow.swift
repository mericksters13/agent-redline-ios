#if AGENT_REDLINE && canImport(UIKit)
import SwiftUI
import UIKit

/// Redline's own window, above the app. Touches pass through to the app
/// except while Redline is active or on the floating button. Screenshots are
/// drawn from the app's windows only, so nothing in this window ever appears in them.
final class OverlayWindow: UIWindow {
    var claimsAllTouches = false
    /// What takes touches while Redline is idle, such as the floating button and a
    /// suggested screenshot, by name.
    var touchableRects: [String: CGRect] = [:]
    var onLayout: ((OverlayWindow) -> Void)?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard claimsAllTouches || touchableRects.values.contains(where: { $0.contains(point) }) else { return nil }
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

/// Finds the window scene the app's root view lives in and installs Redline there.
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
