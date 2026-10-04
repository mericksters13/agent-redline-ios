#if REDLINE && canImport(UIKit)
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
    /// The project file that attached the kit, filled in by the compiler at the call site.
    let sourceFile: StaticString

    func makeUIView(context: Context) -> HookView { HookView(sourceFile: "\(sourceFile)") }
    func updateUIView(_ uiView: HookView, context: Context) {}

    final class HookView: UIView {
        private let sourceFile: String

        init(sourceFile: String) {
            self.sourceFile = sourceFile
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let window, !(window is OverlayWindow), let scene = window.windowScene else { return }
            DebugSession.shared.install(in: scene, sourceFile: sourceFile)
        }
    }
}
#endif
