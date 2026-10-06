import SwiftUI

/// A recipe in the demo's sample data.
struct Recipe: Identifiable, Hashable {
    /// The meal a recipe is for, which sets its tint.
    enum Course: String {
        case breakfast = "Breakfast"
        case lunch = "Lunch"
        case dinner = "Dinner"
        case dessert = "Dessert"

        var tint: Color {
            switch self {
            case .breakfast: .orange
            case .lunch: .green
            case .dinner: .indigo
            case .dessert: .pink
            }
        }
    }

    /// How much work a recipe is.
    enum Difficulty: String {
        case easy = "Easy"
        case medium = "Medium"
        case involved = "Involved"
    }

    /// A stable slug, also used in the list row's accessibility identifier.
    let id: String
    let name: String
    /// One line for the list row and the detail view's subtitle.
    let summary: String
    /// An SF Symbol name.
    let symbol: String
    let course: Course
    let cuisine: String
    let minutes: Int
    let servings: Int
    let calories: Int
    let difficulty: Difficulty
    let about: String
    let ingredients: [String]
    let steps: [String]

    /// The total time, for formatting.
    var time: Duration { .seconds(minutes * 60) }
}
