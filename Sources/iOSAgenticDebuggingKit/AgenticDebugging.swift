import SwiftUI

public extension View {
    /// Installs iOSAgenticDebuggingKit. Attach it once, at the app's root view.
    ///
    /// In Debug builds, knocking twice on the back of the phone opens pick mode.
    /// In release builds, including TestFlight, this returns the view unchanged.
    func agenticDebugging() -> some View {
        #if AGENTIC_DEBUGGING && canImport(UIKit)
        background(SceneHook().allowsHitTesting(false))
        #else
        self
        #endif
    }
}
