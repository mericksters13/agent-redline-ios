#if REDLINE && canImport(UIKit)
import SwiftUI

/// Redline's colors: black surfaces and white type, like the Dynamic Island and other system
/// overlays.
///
/// The same on top of any app, light or dark.
enum Mono {
    static let surface = Color.black
    static let text = Color.white
    static let secondary = Color.white.opacity(0.6)
    /// Fields and secondary buttons on a black surface.
    static let fill = Color.white.opacity(0.12)
    static let hairline = Color.white.opacity(0.16)
}

/// A white number in a circle: a note's place in the list.
struct NumberBadge: View {
    let number: Int
    let size: CGFloat

    var body: some View {
        Text("\(number)")
            .font(.caption.weight(.bold).monospacedDigit())
            .foregroundStyle(Color.black)
            .frame(minWidth: size, minHeight: size)
            .background(Color.white, in: Circle())
            .overlay(Circle().strokeBorder(Color.black, lineWidth: 1.5))
    }
}
#endif
