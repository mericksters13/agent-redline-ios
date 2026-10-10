#if REDLINE
import SwiftUI

/// Fixtures are independent of the inspector. No modifier constants are passed to Redline.
struct LayoutPrototypeScreen: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Layout prototype").font(.title.bold())
            Text("Tap Redline, then a sample. Try repeated and overlapping samples.")
                .font(.caption)
            Text("Fixed")
                .padding(.horizontal, 16)
                .frame(width: 180, height: 44, alignment: .leading)
                .background(.blue.opacity(0.15))
            Text("Nested")
                .padding(.leading, 5)
                .padding(.leading, 5)
                .frame(width: 120, height: 36)
                .background(.cyan.opacity(0.15))
            Text("Flexible")
                .padding(.top, 7)
                .frame(minWidth: 100, idealWidth: 160, maxWidth: .infinity, minHeight: 40, alignment: .trailing)
                .background(.green.opacity(0.15))
            Text("Default padding").padding().background(.orange.opacity(0.15))
            HStack(alignment: .top, spacing: 12) {
                Text("Left").padding(6).layoutPriority(3)
                Text("Right").padding(10)
            }
            .background(.purple.opacity(0.15))
            HStack(spacing: 20) {
                Text("Duplicate").padding(4)
                Text("Duplicate").padding(20)
            }
            ZStack {
                Text("Overlap").padding(4)
                Text("Overlap").padding(18).background(.yellow.opacity(0.5))
            }
            if UserDefaults.standard.bool(forKey: "RedlineLayoutButtonDemo") {
                Button("Continue") {}
                    .buttonStyle(.plain)
                    .padding(.horizontal, 8)
                    .frame(width: 160, height: 44, alignment: .leading)
                    .background(.blue.opacity(0.15))
            } else {
                Text("Visible content")
                    .padding(9)
                    .accessibilityRepresentation { Text("Synthetic selection") }
            }
            Spacer()
        }
        .padding(20)
        .task {
            if UserDefaults.standard.string(forKey: "RedlineLayoutActivation") == "late" {
                try? await Task.sleep(for: .seconds(1))
                setenv("SWIFTUI_VIEW_DEBUG", "287", 1)
            }
        }
    }
}
#endif
