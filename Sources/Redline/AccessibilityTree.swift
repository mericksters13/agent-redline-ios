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
    /// Frames are cut to the screen and to every enclosing view that clips, such as a scroll view,
    /// so a row scrolled out of sight can't be picked over what covers it.
    ///
    /// With `stopAtFirst`, the walk ends at the first element found, to tell whether there are any.
    static func elements(under roots: [UIView], screenBounds: CGRect, stopAtFirst: Bool = false) -> [ElementSnapshot] {
        var result: [ElementSnapshot] = []
        var visited = Set<ObjectIdentifier>()

        func append(_ object: NSObject, isContainer: Bool, parent: Int?, clip: CGRect) -> Int? {
            var frame = object.accessibilityFrame
            if frame.isEmpty, let view = object as? UIView, let window = view.window {
                frame = view.convert(view.bounds, to: window.screen.coordinateSpace)
            }
            frame = frame.intersection(clip)
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
                    updatesFrequently: updatesFrequently(object) ? true : nil,
                    parent: parent
                )
            )
            return result.count - 1
        }

        func visit(_ object: NSObject, depth: Int, parent: Int?, clip: CGRect) {
            if stopAtFirst, !result.isEmpty { return }
            guard depth < 80, visited.insert(ObjectIdentifier(object)).inserted else { return }
            if let view = object as? UIView, view.isHidden || view.alpha < 0.01 { return }

            var clip = clip
            if let view = object as? UIView, view.clipsToBounds, let window = view.window {
                clip = clip.intersection(view.convert(view.bounds, to: window.screen.coordinateSpace))
                guard !clip.isNull, !clip.isEmpty else { return }
            }

            var parent = parent
            if object.isAccessibilityElement {
                parent = append(object, isContainer: false, parent: parent, clip: clip) ?? parent
            } else if identifier(of: object) != nil || object.accessibilityLabel?.nonEmpty != nil {
                // Named groups let the note box step up from a leaf to its card or section.
                parent = append(object, isContainer: true, parent: parent, clip: clip) ?? parent
            }

            if let children = object.accessibilityElements {
                for case let child as NSObject in children {
                    visit(child, depth: depth + 1, parent: parent, clip: clip)
                }
            } else {
                // SwiftUI hosting views expose their tree through the container methods.
                let count = object.accessibilityElementCount()
                if count > 0, count != NSNotFound {
                    for index in 0..<min(count, 500) {
                        if let child = object.accessibilityElement(at: index) as? NSObject {
                            visit(child, depth: depth + 1, parent: parent, clip: clip)
                        }
                    }
                }
            }
            if let view = object as? UIView {
                for subview in view.subviews { visit(subview, depth: depth + 1, parent: parent, clip: clip) }
            }
        }

        for root in roots { visit(root, depth: 0, parent: nil, clip: screenBounds) }
        return result
    }

    /// The screen the user is looking at: the navigation bar title, else the
    /// topmost header on screen (custom headers such as a large "Today"), else the
    /// selected tab, plus the view controller type.
    ///
    /// A sheet or full-screen cover is read alone, so it never takes the title of the screen it
    /// covers; a translucent presentation takes the title of the screen still showing under it,
    /// front first.
    static func screen(of window: UIWindow?, elements: [ElementSnapshot]) -> ScreenInfo {
        guard let window else { return ScreenInfo() }
        let controller = topController(of: window)
        let cover = coveringController(in: window)
        let title =
            visibleRoots(of: window).reversed().lazy.compactMap(navigationBarTitle(in:)).first
            ?? ElementSelection.headerTitle(in: elements)
            ?? selectedTabTitle(from: cover ?? window.rootViewController)
            ?? controller?.navigationItem.title?.nonEmpty
            ?? controller?.title?.nonEmpty
        let typeName = controller.map {
            String(describing: type(of: $0)).split(separator: "<").first.map(String.init) ?? ""
        }
        return ScreenInfo(title: title, viewController: typeName?.nonEmpty)
    }

    /// The view controller showing the screen in `window`: the topmost presented one, or the
    /// visible one inside navigation and tab controllers.
    static func topController(of window: UIWindow?) -> UIViewController? {
        topController(from: window?.rootViewController)
    }

    // MARK: - Presented screens

    /// The views that make up what is on screen in `window`, back to front.
    ///
    /// A sheet or a full-screen cover hides what's under it, so reading starts again at its view,
    /// along with anything drawn in the window above it, such as a menu opened from it. An
    /// over-context, over-full-screen or custom presentation that keeps the presenting view leaves
    /// that view showing unless its own view is opaque and covers the window, so both are read. An
    /// open menu's empty presented controller hides nothing.
    private static func visibleRoots(of window: UIWindow) -> [UIView] {
        var roots: [UIView] = [window]
        var controller = window.rootViewController
        while let presented = controller?.presentedViewController, !presented.isBeingDismissed {
            controller = presented
            guard let view = presented.viewIfLoaded, showsContent(presented) else { continue }
            if hidesPresenter(presented, in: window) {
                var top: UIView = view
                while let parent = top.superview, parent !== window { top = parent }
                let above = window.subviews.firstIndex(of: top).map { window.subviews[($0 + 1)...] } ?? []
                roots = [view] + above
            } else {
                roots.append(view)
            }
        }
        return roots
    }

    /// Whether a presentation hides the screen it was presented from.
    private static func hidesPresenter(_ controller: UIViewController, in window: UIWindow) -> Bool {
        switch controller.modalPresentationStyle {
        case .overFullScreen, .overCurrentContext:
            break
        case .custom where controller.presentationController?.shouldRemovePresentersView == false:
            break
        default:
            return true
        }
        return coversWindow(controller, in: window)
    }

    /// Whether a presented controller's own view is opaque and covers the whole window.
    private static func coversWindow(_ controller: UIViewController, in window: UIWindow) -> Bool {
        guard let view = controller.viewIfLoaded else { return false }
        let backgroundAlpha = view.backgroundColor?.resolvedColor(with: view.traitCollection).cgColor.alpha ?? 0
        return backgroundAlpha > 0.99 && view.alpha > 0.99
            && view.convert(view.bounds, to: window).contains(window.bounds)
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
    /// Such a presentation hides nothing and isn't a new screen. One that is opaque over the whole
    /// window hides the screen under it even when it has nothing for accessibility, so it counts as
    /// showing something; a menu's presentation, which the screen shows through, never is.
    private static func showsContent(_ controller: UIViewController) -> Bool {
        guard let view = controller.viewIfLoaded, let window = view.window else { return false }
        if coversWindow(controller, in: window) { return true }
        return !elements(under: [view], screenBounds: window.bounds, stopAtFirst: true).isEmpty
    }

    // MARK: - Element details

    /// Content that changes on its own, such as a spinner or a running timer.
    private static func updatesFrequently(_ object: NSObject) -> Bool {
        object is UIActivityIndicatorView || object.accessibilityTraits.contains(.updatesFrequently)
    }

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
