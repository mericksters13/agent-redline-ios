import SwiftUI

/// A recipe's detail view: a header, the stats, the Start cooking button, then the full recipe.
struct RecipeDetail: View {
    let recipe: Recipe

    @State private var isCooking = false
    @ScaledMetric(relativeTo: .largeTitle) private var headerHeight: CGFloat = 180

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                titles
                stats
                startButton
                section("About") {
                    Text(recipe.about)
                }
                section("Ingredients") {
                    ingredients
                }
                section("Method") {
                    method
                }
            }
            .padding()
        }
        .navigationTitle(recipe.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Header

    private var header: some View {
        RoundedRectangle(cornerRadius: 20)
            .fill(recipe.course.tint.gradient)
            .frame(height: headerHeight)
            .overlay {
                Image(systemName: recipe.symbol)
                    .font(.system(size: 72))
                    .foregroundStyle(.white)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(recipe.course.rawValue) recipe")
            .accessibilityAddTraits(.isImage)
            .accessibilityIdentifier("detail.header")
    }

    private var titles: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(recipe.name)
                .font(.largeTitle.bold())
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("detail.title")
            Text(recipe.summary)
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail.titles")
    }

    // MARK: - Stats

    private var stats: some View {
        Grid(horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                StatCell(title: "Time", symbol: "clock") {
                    Text(recipe.time, format: .units(allowed: [.hours, .minutes], width: .abbreviated))
                }
                StatCell(title: "Serves", symbol: "person.2") {
                    Text(recipe.servings, format: .number)
                }
            }
            GridRow {
                StatCell(title: "Calories", symbol: "bolt.heart") {
                    Text(recipe.calories, format: .number)
                }
                StatCell(title: "Difficulty", symbol: "chart.bar") {
                    Text(recipe.difficulty.rawValue)
                }
            }
            GridRow {
                StatCell(title: "Course", symbol: "fork.knife") {
                    Text(recipe.course.rawValue)
                }
                StatCell(title: "Cuisine", symbol: "globe") {
                    Text(recipe.cuisine)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail.stats")
    }

    private var startButton: some View {
        Button {
            isCooking.toggle()
        } label: {
            Label(isCooking ? "Stop cooking" : "Start cooking", systemImage: isCooking ? "stop.fill" : "play.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(recipe.course.tint)
        // Planted bug for the demo: a leading inset with no matching trailing one, so the button sits right of center.
        .padding(.leading, 44)
        .accessibilityIdentifier("detail.start")
    }

    // MARK: - Recipe

    private var ingredients: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Each recipe lists an ingredient once, so the text is a stable ID.
            ForEach(recipe.ingredients, id: \.self) { ingredient in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 6))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(ingredient)
                }
            }
        }
    }

    private var method: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(recipe.steps.enumerated()), id: \.element) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(index + 1, format: .number)
                        .font(.headline)
                        .monospacedDigit()
                        .foregroundStyle(recipe.course.tint)
                    Text(step)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func section(_ title: LocalizedStringKey, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }
}

/// One figure in the stats grid, such as the total time.
private struct StatCell<Value: View>: View {
    let title: LocalizedStringKey
    let symbol: String
    @ViewBuilder let value: Value

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
            value
                .font(.title3.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.fill.tertiary, in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}
