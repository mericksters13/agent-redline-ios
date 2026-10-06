import SwiftUI

/// The UIKit tab: a UIKit view controller hosted in SwiftUI, under a navigation title that says so.
struct UIKitScreen: View {
    var body: some View {
        NavigationStack {
            ShoppingList()
                .navigationTitle("UIKit")
        }
    }
}

/// Hosts ``ShoppingListViewController`` in SwiftUI.
private struct ShoppingList: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> ShoppingListViewController {
        ShoppingListViewController()
    }

    // The controller keeps its own state, so there is nothing to update.
    func updateUIViewController(_ controller: ShoppingListViewController, context: Context) {}
}
