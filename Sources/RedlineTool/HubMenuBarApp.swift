#if os(macOS)
import AppKit
import SwiftUI
import UserNotifications

/// The hub as a menu bar app: the same process takes reports off phones and simulators, and its
/// menu bar panel shows the devices that are active and the reports sent, with where each went.
///
/// It refreshes only while the panel is open, so it costs nothing while closed.
struct HubMenuBarApp: App {
    @NSApplicationDelegateAdaptor(HubAppDelegate.self) private var delegate
    @State private var model = HubWindowModel(hub: HubAppContext.hub)

    var body: some Scene {
        MenuBarExtra {
            HubPanel(model: model)
        } label: {
            Image(nsImage: MenuBarIcon.image)
                .accessibilityLabel("Redline")
        }
        .menuBarExtraStyle(.window)
    }
}

/// The menu bar icon: the app icon's phone with a marked element and its note number, as a
/// template image the menu bar tints for light and dark.
private enum MenuBarIcon {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let badge = CGRect(x: 10.5, y: 1.2, width: 6, height: 6)
            context.setFillColor(NSColor.black.cgColor)
            context.setStrokeColor(NSColor.black.cgColor)
            // The phone and its marked element, cut back around the badge so the two stay apart.
            context.saveGState()
            context.addRect(CGRect(x: 0, y: 0, width: 18, height: 18))
            context.addEllipse(in: badge.insetBy(dx: -1.3, dy: -1.3))
            context.clip(using: .evenOdd)
            context.setLineWidth(1.5)
            context.addPath(
                CGPath(
                    roundedRect: CGRect(x: 4.5, y: 1.25, width: 9, height: 15.5),
                    cornerWidth: 2.8,
                    cornerHeight: 2.8,
                    transform: nil
                )
            )
            context.strokePath()
            context.addPath(
                CGPath(
                    roundedRect: CGRect(x: 6.3, y: 7, width: 5.4, height: 3.4),
                    cornerWidth: 1,
                    cornerHeight: 1,
                    transform: nil
                )
            )
            context.fillPath()
            context.restoreGState()
            context.fillEllipse(in: badge)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Redline"
        return image
    }()
}

/// Stops the hub when the app quits, from the panel's Quit button, the Dock or logging out, so it
/// releases `hub.pid` and logs that it stopped.
///
/// Termination signals stop it on their own.
private final class HubAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        HubAppContext.hub?.stop()
    }
}

/// Shows Redline's notifications while the app is in front too, such as while its panel is open.
///
/// Without it, macOS hands them to the app and shows nothing.
final class ForegroundNotifications: NSObject, UNUserNotificationCenterDelegate, Sendable {
    /// The notification center keeps its delegate weakly, so this one stays for the app's life.
    static let shared = ForegroundNotifications()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }
}

/// Hands the running hub to the app, which SwiftUI creates on its own.
///
/// Set by `redline app` before the app starts, on the main actor.
@MainActor
enum HubAppContext {
    static var hub: Hub!
}
#endif
