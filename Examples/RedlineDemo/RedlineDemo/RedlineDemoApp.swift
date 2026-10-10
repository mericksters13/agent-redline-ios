import Redline
import SwiftUI

@main
struct RedlineDemoApp: App {
    init() {
        #if REDLINE
        let defaults = UserDefaults.standard
        defaults.register(defaults: ["RedlineLayoutInspection": true])
        let activation = defaults.string(forKey: "RedlineLayoutActivation") ?? "early"
        if activation == "early" {
            setenv("SWIFTUI_VIEW_DEBUG", "287", 1)
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            Group {
                #if REDLINE
                if UserDefaults.standard.bool(forKey: "RedlineLayoutPrototype") {
                    LayoutPrototypeScreen()
                } else {
                    regularDemo
                }
                #else
                regularDemo
                #endif
            }
            .redline()
        }
    }

    @ViewBuilder private var regularDemo: some View {
        if UserDefaults.standard.bool(forKey: "RedlineKeyboardLayoutDemo") {
            KeyboardLayoutScreen()
        } else {
            DemoTabs()
        }
    }
}
