import SwiftUI

/// The Plan tab: a form that plans a meal around one of the recipes.
struct MealPlanForm: View {
    /// What the last Save recorded, shown under the button.
    private struct Plan {
        let title: String
        let recipe: String
        let date: Date
        let remindsMe: Bool
    }

    @State private var title = ""
    @State private var notes = ""
    @State private var date = Date.now
    @State private var remindsMe = true
    @State private var recipeID = Recipe.tonight.id
    @State private var savedPlan: Plan?

    var body: some View {
        NavigationStack {
            Form {
                Section("Meal") {
                    TextField("Title", text: $title, prompt: Text("Friday dinner"))
                        .accessibilityIdentifier("form.title")
                    TextField("Notes", text: $notes, prompt: Text("Guests, allergies, what to buy"), axis: .vertical)
                        .lineLimit(3...6)
                        .accessibilityIdentifier("form.notes")
                }
                Section("When") {
                    DatePicker("Date", selection: $date, displayedComponents: [.date, .hourAndMinute])
                        .accessibilityIdentifier("form.date")
                    Toggle("Remind me an hour before", isOn: $remindsMe)
                        .accessibilityIdentifier("form.reminder")
                }
                Section("Recipe") {
                    Picker("Recipe", selection: $recipeID) {
                        ForEach(Recipe.samples) { recipe in
                            Text(recipe.name).tag(recipe.id)
                        }
                    }
                    .accessibilityIdentifier("form.recipe")
                }
                Section {
                    Button(action: save) {
                        Text("Save")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("form.save")
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                } footer: {
                    if let savedPlan {
                        savedMessage(savedPlan)
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Plan a Meal")
        }
    }

    /// Records the form's values as the saved plan.
    private func save() {
        let recipe = Recipe.samples.first { $0.id == recipeID } ?? Recipe.tonight
        savedPlan = Plan(
            title: title.trimmingCharacters(in: .whitespaces),
            recipe: recipe.name,
            date: date,
            remindsMe: remindsMe
        )
    }

    private func savedMessage(_ plan: Plan) -> Text {
        let when = Text(plan.date, format: .dateTime.weekday(.wide).month().day().hour().minute())
        if plan.remindsMe {
            return Text("Saved \(plan.title): \(plan.recipe), \(when), with a reminder an hour before.")
        }
        return Text("Saved \(plan.title): \(plan.recipe), \(when).")
    }
}
