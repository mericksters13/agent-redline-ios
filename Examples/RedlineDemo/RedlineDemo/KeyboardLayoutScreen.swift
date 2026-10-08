import SwiftUI

/// A screen whose flexible layout moves when a keyboard appears in the scene.
///
/// Used to check that Redline keeps its selected heading and snapshot together.
struct KeyboardLayoutScreen: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ProgressView(value: 0.25)
                .tint(.purple)
                .padding(.top, 20)

            Spacer(minLength: 0)

            RoundedRectangle(cornerRadius: 24)
                .fill(.purple.opacity(0.15))
                .frame(height: 160)
                .overlay {
                    Image(systemName: "square.stack.3d.up")
                        .font(.system(size: 64))
                        .foregroundStyle(.purple)
                }
                .accessibilityHidden(true)

            Text("Keep the selected heading in place")
                .font(.largeTitle.bold())
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("keyboard.heading")

            Text(
                "Annotate this heading, then write a note. Its outline should stay on the heading when the keyboard opens."
            )
            .font(.body)
            .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            Button("Continue", action: {})
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(.purple)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("keyboard.continue")
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .preferredColorScheme(.dark)
    }
}
