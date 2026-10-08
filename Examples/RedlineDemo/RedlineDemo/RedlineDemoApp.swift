import Redline
import SwiftUI

/// The demo's entry point: four tabs, with Redline on the root view.
@main
struct RedlineDemoApp: App {
    var body: some Scene {
        WindowGroup {
            Group {
                if UserDefaults.standard.bool(forKey: "RedlineKeyboardLayoutDemo") {
                    KeyboardLayoutScreen()
                } else {
                    DemoTabs()
                }
            }
            .redline()  // Debug builds only: in Release, .redline() returns the view unchanged.
        }
    }
}
