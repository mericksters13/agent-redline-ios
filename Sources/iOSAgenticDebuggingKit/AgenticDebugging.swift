import SwiftUI

public extension View {
    /// Installs iOSAgenticDebuggingKit. Attach it once, at the app's root view.
    ///
    /// In Debug builds, a floating button opens pick mode. Drag it anywhere; it
    /// snaps to the nearest screen edge.
    /// In release builds, including TestFlight, this returns the view unchanged.
    func agenticDebugging() -> some View {
        #if AGENTIC_DEBUGGING && canImport(UIKit)
        background(SceneHook().allowsHitTesting(false))
        #else
        self
        #endif
    }
}
