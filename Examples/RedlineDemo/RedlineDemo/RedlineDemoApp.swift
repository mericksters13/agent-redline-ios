import Redline
import SwiftUI

@main
struct RedlineDemoApp: App {
    init() {
        #if REDLINE
        if UserDefaults.standard.bool(forKey: "RedlineLayoutPrototype"),
           UserDefaults.standard.string(forKey: "RedlineLayoutActivation") == "early" {
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
