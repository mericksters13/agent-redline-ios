import SwiftUI

public extension View {
    /// Installs Redline. Attach it once, at the app's root view.
    ///
    /// In Debug builds, a floating button opens pick mode. Drag it anywhere; it
    /// snaps to the nearest screen edge. A screenshot taken in the app is offered
    /// beside the button, ready to send with a note.
    ///
    /// Nothing else is needed: no Info.plist keys, permissions or build settings.
    /// In release builds, including TestFlight, this returns the view unchanged.
    ///
    /// - Parameter sourceFile: Leave it out. The compiler fills it in, and the Mac uses it to
    ///   tell which project folder the app was built from.
    func redline(sourceFile: StaticString = #filePath) -> some View {
        #if REDLINE && canImport(UIKit)
        BuildIdentity.sourceFile = "\(sourceFile)"
        return background(SceneHook().allowsHitTesting(false))
        #else
        self
        #endif
    }
}
