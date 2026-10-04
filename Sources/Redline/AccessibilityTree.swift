#if REDLINE && canImport(UIKit)
import Darwin
import UIKit

/// Reads the app's accessibility tree, the closest thing iOS has to a DOM: roles,
/// labels, identifiers and frames for SwiftUI and UIKit alike.
///
/// The walk and the automation switch follow AnnotateKit's approach
/// (https://github.com/Connected-Mate/AnnotateKit, MIT).
@MainActor
enum AccessibilityTree {
    private static var isAutomationEnabled = false

    /// SwiftUI builds its accessibility tree only when an assistive client is connected.
    ///
    /// Turn on the automation mode UI testing uses so the tree exists when we read it. Debug builds
    /// only.
    static func enableAutomation() {
        guard !isAutomationEnabled else { return }
        isAutomationEnabled = true
        guard let handle = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW) else {
            Log.accessibility.error("Couldn't open libAccessibility; SwiftUI screens may show no elements")
            return
        }
        guard let symbol = dlsym(handle, "AXSSetAutomationEnabled") ?? dlsym(handle, "_AXSSetAutomationEnabled") else {
            Log.accessibility.error("AXSSetAutomationEnabled is missing; SwiftUI screens may show no elements")
            return
        }
        typealias Setter = @convention(c) (Int32) -> Void
        unsafeBitCast(symbol, to: Setter.self)(1)
    }

    /// The views to read in `windows`: each window, or only what a presented sheet shows.
    static func visibleRoots(in windows: [UIWindow]) -> [UIView] {
        windows.flatMap(visibleRoots(of:))
    }

    /// Every element and named group under `roots`, in screen points: back to front, each
    /// parent before its children, with `parent` set to the enclosing one.
    ///
    /// With `stopAtFirst`, the walk ends at the first element found, to tell whether there are any.
    static func elements(under roots: [UIView], screenBounds: CGRect, stopAtFirst: Bool = false) -> [ElementSnapshot] {
        var result: [ElementSnapshot] = []
        var visited = Set<ObjectIdentifier>()

        func append(_ object: NSObject, isContainer: Bool, parent: Int?) -> Int? {
            var frame = object.accessibilityFrame
            if frame.isEmpty, let view = object as? UIView, let window = view.window {
                frame = view.convert(view.bounds, to: window.screen.coordinateSpace)
            }
            frame = frame.intersection(screenBounds)
            guard !frame.isNull, !frame.isEmpty else { return nil }
            result.append(
                ElementSnapshot(
                    role: role(of: object, isContainer: isContainer),
                    label: object.accessibilityLabel?.nonEmpty,
                    value: object.accessibilityValue?.nonEmpty,
                    identifier: identifier(of: object),
                    className: String(describing: type(of: object)),
                    isContainer: isContainer,
                    frame: frame,
                    parent: parent
                )
            )
            return result.count - 1
        }

        func visit(_ object: NSObject, depth: Int, parent: Int?) {
            if stopAtFirst, !result.isEmpty { return }
            guard depth < 80, visited.insert(ObjectIdentifier(object)).inserted else { return }
            if let view = object as? UIView, view.isHidden || view.alpha < 0.01 { return }

            var parent = parent
            if object.isAccessibilityElement {
                parent = append(object, isContainer: false, parent: parent) ?? parent
            } else if identifier(of: object) != nil || object.accessibilityLabel?.nonEmpty != nil {
                // Named groups let the note box step up from a leaf to its card or section.
                parent = append(object, isContainer: true, parent: parent) ?? parent
            }

            if let children = object.accessibilityElements {
                for case let child as NSObject in children { visit(child, depth: depth + 1, parent: parent) }
            } else {
                // SwiftUI hosting views expose their tree through the container methods.
                let count = object.accessibilityElementCount()
                if count > 0, count != NSNotFound {
                    for index in 0..<min(count, 500) {
                        if let child = object.accessibilityElement(at: index) as? NSObject {
                            visit(child, depth: depth + 1, parent: parent)
                        }
                    }
                }
            }
            if let view = object as? UIView {
                for subview in view.subviews { visit(subview, depth: depth + 1, parent: parent) }
            }
        }

        for root in roots { visit(root, depth: 0, parent: nil) }
        return result
    }

    /// The screen the user is looking at: the navigation bar title, else the
    /// topmost header on screen (custom headers such as a large "Today"), else the
    /// selected tab, plus the view controller type.
    static func screen(of window: UIWindow?, elements: [ElementSnapshot]) -> ScreenInfo {
        guard let window else { return ScreenInfo() }
        let controller = topController(from: window.rootViewController)
        let title =
            navigationBarTitle(in: window)
            ?? ElementSelection.headerTitle(in: elements)
            ?? selectedTabTitle(from: window.rootViewController)
            ?? controller?.navigationItem.title?.nonEmpty
            ?? controller?.title?.nonEmpty
        let typeName = controller.map {
            String(describing: type(of: $0)).split(separator: "<").first.map(String.init) ?? ""
        }
        return ScreenInfo(title: title, viewController: typeName?.nonEmpty)
    }

    // MARK: - Presented screens

    /// A presented sheet or full-screen cover hides what's under it, so only its view is
    /// read when one is up, along with anything drawn above it, such as a menu opened from it.
    private static func visibleRoots(of window: UIWindow) -> [UIView] {
        guard let cover = coveringController(in: window)?.viewIfLoaded else { return [window] }
        var top: UIView = cover
        while let parent = top.superview, parent !== window { top = parent }
        guard let index = window.subviews.firstIndex(of: top) else { return [cover] }
        return [cover] + window.subviews[(index + 1)...]
    }

    /// The topmost presented controller that shows something of its own.
    private static func coveringController(in window: UIWindow) -> UIViewController? {
        var controller = window.rootViewController
        var covering: UIViewController?
        while let presented = controller?.presentedViewController, !presented.isBeingDismissed {
            controller = presented
            if showsContent(presented) { covering = presented }
        }
        return covering
    }

    /// An open menu presents an empty controller and draws its items in the window, over the screen
    /// it opened from.
    ///
    /// Such a presentation hides nothing and isn't a new screen.
    private static func showsContent(_ controller: UIViewController) -> Bool {
        guard let view = controller.viewIfLoaded, let window = view.window else { return false }
        return !elements(under: [view], screenBounds: window.bounds, stopAtFirst: true).isEmpty
    }

    // MARK: - Element details

    private static func role(of object: NSObject, isContainer: Bool) -> String {
        if object is UISearchBar { return "Search field" }
        if object is UITextField || object is UITextView { return "Text field" }
        if object is UISwitch { return "Toggle" }
        let traits = object.accessibilityTraits
        if traits.contains(.searchField) { return "Search field" }
        if traits.contains(.keyboardKey) { return "Key" }
        if traits.contains(.toggleButton) { return "Toggle" }
        if traits.contains(.button) { return "Button" }
        if traits.contains(.link) { return "Link" }
        if traits.contains(.adjustable) { return "Adjustable" }
        if traits.contains(.tabBar) { return "Tab bar" }
        if traits.contains(.header) { return ElementSnapshot.headerRole }
        if traits.contains(.image) { return "Image" }
        if traits.contains(.staticText) { return "Text" }
        return isContainer ? "Group" : "Element"
    }

    /// SwiftUI's accessibility nodes answer `accessibilityIdentifier` without
    /// declaring the protocol, so ask by selector as well.
    private static func identifier(of object: NSObject) -> String? {
        if let identifier = (object as? UIAccessibilityIdentification)?.accessibilityIdentifier?.nonEmpty {
            return identifier
        }
        let selector = NSSelectorFromString("accessibilityIdentifier")
        guard object.responds(to: selector),
            let value = object.perform(selector)?.takeUnretainedValue() as? String
        else { return nil }
        return value.nonEmpty
    }

    private static func topController(from controller: UIViewController?) -> UIViewController? {
        guard let controller else { return nil }
        if let presented = controller.presentedViewController, !presented.isBeingDismissed, showsContent(presented) {
            return topController(from: presented)
        }
        if let navigation = controller as? UINavigationController {
            // Not `visibleViewController`: that is any presented controller, an open menu's included.
            return navigation.topViewController.map { topController(from: $0) ?? $0 }
        }
        if let tabs = controller as? UITabBarController {
            return topController(from: tabs.selectedViewController) ?? tabs
        }
        // SwiftUI hosts its navigation and tab controllers as children.
        for child in controller.children.reversed() where child.viewIfLoaded?.window != nil {
            if child is UINavigationController || child is UITabBarController || !child.children.isEmpty,
                let found = topController(from: child)
            {
                return found
            }
        }
        return controller
    }

    private static func selectedTabTitle(from controller: UIViewController?) -> String? {
        guard let controller else { return nil }
        if let tabs = controller as? UITabBarController {
            return tabs.selectedViewController?.tabBarItem.title?.nonEmpty ?? tabs.tabBar.selectedItem?.title?.nonEmpty
        }
        for child in controller.children {
            if let title = selectedTabTitle(from: child) { return title }
        }
        return nil
    }

    private static func navigationBarTitle(in view: UIView) -> String? {
        if let bar = view as? UINavigationBar, !bar.isHidden, bar.alpha > 0.01, bar.window != nil,
            let title = bar.topItem?.title?.nonEmpty
        {
            return title
        }
        for subview in view.subviews where !subview.isHidden {
            if let title = navigationBarTitle(in: subview) { return title }
        }
        return nil
    }
}
#endif
