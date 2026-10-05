#if os(macOS)
import AppKit
import SwiftUI

/// One window per report, opened from the panel.
@MainActor
enum ReportWindows {
    private struct OpenWindow {
        var window: NSWindow
        var observer: any NSObjectProtocol
    }

    private static var windows: [URL: OpenWindow] = [:]
    /// Where the next new window goes, so each opens below and right of the last, not on top of it.
    private static var cascadePoint = NSPoint.zero
    /// Reports whose files are being read before their window shows, and whether the last click
    /// only refreshes a window that was open then; a second click waits for the same read.
    private static var loading: [URL: Bool] = [:]

    /// Opens the report's window, or brings it forward, in front of the other apps: Redline is a
    /// menu bar app, so it isn't active when the panel is clicked.
    ///
    /// An open window reads the report again, since it may have gone to a chat since it opened. The
    /// report's files are read off the main actor first. A window closed while it was being
    /// refreshed stays closed.
    static func show(_ report: HubWindowModel.ReportRow) {
        let folder = report.folder
        guard loading.updateValue(windows[folder] != nil, forKey: folder) == nil else { return }
        Task {
            let contents = await ReportViewer.load(folder)
            let isRefresh = loading.removeValue(forKey: folder) == true
            guard !isRefresh || windows[folder] != nil else { return }
            present(report, contents)
        }
    }

    private static func present(_ report: HubWindowModel.ReportRow, _ contents: ReportViewer.Contents) {
        defer { NSApp.activate() }
        if let window = windows[report.folder]?.window {
            window.title = ReportViewer.title(of: report)
            (window.contentViewController as? NSHostingController<ReportViewer>)?.rootView = ReportViewer(
                report: report,
                contents: contents
            )
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = ReportViewer.title(of: report)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .black
        window.contentViewController = NSHostingController(rootView: ReportViewer(report: report, contents: contents))
        if windows.isEmpty { window.center() }
        cascadePoint = window.cascadeTopLeft(from: cascadePoint)
        let folder = report.folder
        // queue: .main delivers on the main thread.
        let observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                if let observer = windows[folder]?.observer { NotificationCenter.default.removeObserver(observer) }
                windows[folder] = nil
            }
        }
        windows[folder] = OpenWindow(window: window, observer: observer)
        window.makeKeyAndOrderFront(nil)
    }
}
#endif
