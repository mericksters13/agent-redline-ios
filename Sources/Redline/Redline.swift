import SwiftUI

extension View {
    #if REDLINE && canImport(UIKit)
    /// Adds the Redline overlay to this view's scene in Debug builds.
    ///
    /// Attach it once, at the app's root view. A floating button opens pick mode. Drag it
    /// anywhere; it snaps to the nearest screen edge. A screenshot taken in the app is offered
    /// beside the button, ready to send with a note.
    ///
    /// The overlay lives in the first window scene the modifier is attached in. Attaching it
    /// again, in the same scene or another one, has no further effect, and the first
    /// attachment's source file is the one the Mac sees.
    ///
    /// Nothing else is needed: no Info.plist keys, permissions or build settings. In Release
    /// builds, including TestFlight, nothing is installed.
    ///
    /// - Parameter sourceFile: Leave it out. The compiler fills it in, and the Mac uses it to
    ///   tell which project folder the app was built from.
    /// - Returns: This view, with the overlay installed behind it.
    public func redline(sourceFile: StaticString = #filePath) -> some View {
        // The path is turned into a string once, when the hook's view is made.
        background(SceneHook(sourceFile: sourceFile).allowsHitTesting(false))
    }
    #else
    /// Returns this view unchanged: Redline is compiled out of this build.
    ///
    /// Inlined so the caller's file path, filled in by the compiler, is optimized away and
    /// not kept in the binary.
    ///
    /// - Parameter sourceFile: Leave it out. Debug builds use it; this build ignores it.
    /// - Returns: This view, unchanged.
    @inlinable
    public func redline(sourceFile: StaticString = #filePath) -> some View { self }
    #endif
}
