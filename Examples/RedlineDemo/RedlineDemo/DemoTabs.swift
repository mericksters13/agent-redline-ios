import SwiftUI

/// The demo's root view: a list, a detail view, a form and a UIKit screen, one tab each.
struct DemoTabs: View {
    var body: some View {
        TabView {
            Tab("Recipes", systemImage: "book") {
                RecipeList()
            }
            Tab("Tonight", systemImage: "fork.knife") {
                NavigationStack {
                    RecipeDetail(recipe: .tonight)
                }
            }
            Tab("Plan", systemImage: "calendar") {
                MealPlanForm()
            }
            Tab("UIKit", systemImage: "switch.2") {
                UIKitScreen()
            }
        }
    }
}
