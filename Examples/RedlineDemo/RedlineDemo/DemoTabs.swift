import SwiftUI

/// Sample screens for annotation, with layout inspection samples in Debug builds.
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
            #if REDLINE
            Tab("Layout", systemImage: "ruler") {
                LayoutPrototypeScreen()
            }
            #endif
        }
    }
}
