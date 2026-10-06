import SwiftUI

/// The Recipes tab: a searchable list of the sample recipes, each opening its detail view.
struct RecipeList: View {
    /// How the list is sorted.
    private enum Order: String, CaseIterable, Identifiable {
        case name = "Name"
        case time = "Time"

        var id: Self { self }
    }

    @State private var query = ""
    @State private var order = Order.name

    var body: some View {
        let recipes = shownRecipes()
        NavigationStack {
            List(recipes) { recipe in
                NavigationLink(value: recipe) {
                    RecipeRow(recipe: recipe)
                }
                .accessibilityIdentifier("list.row.\(recipe.id)")
            }
            .overlay {
                if recipes.isEmpty {
                    ContentUnavailableView.search
                }
            }
            .navigationTitle("Recipes")
            .navigationDestination(for: Recipe.self) { recipe in
                RecipeDetail(recipe: recipe)
            }
            .searchable(text: $query, prompt: "Search recipes")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("Sort", systemImage: "arrow.up.arrow.down") {
                        Picker("Sort by", selection: $order) {
                            ForEach(Order.allCases) { order in
                                Text(order.rawValue).tag(order)
                            }
                        }
                    }
                    .accessibilityIdentifier("list.sort")
                }
            }
        }
    }

    /// The recipes that match the search, in the chosen order.
    private func shownRecipes() -> [Recipe] {
        let matches = Recipe.samples.filter { recipe in
            query.isEmpty
                || recipe.name.localizedStandardContains(query)
                || recipe.summary.localizedStandardContains(query)
                || recipe.cuisine.localizedStandardContains(query)
                || recipe.course.rawValue.localizedStandardContains(query)
        }
        switch order {
        case .name:
            return matches.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .time:
            return matches.sorted { $0.minutes < $1.minutes }
        }
    }
}

/// One recipe in the list: its symbol, name, summary and total time.
private struct RecipeRow: View {
    let recipe: Recipe

    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 40

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: recipe.symbol)
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: iconSize, height: iconSize)
                .background(recipe.course.tint.gradient, in: .rect(cornerRadius: 10))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(recipe.name)
                    .font(.body)
                Text(recipe.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    // Planted bug for the demo: a fixed width cuts the summary off even when the row has room.
                    .frame(width: 150, alignment: .leading)
            }
            Spacer(minLength: 8)
            Text(recipe.time, format: .units(allowed: [.hours, .minutes], width: .abbreviated))
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
