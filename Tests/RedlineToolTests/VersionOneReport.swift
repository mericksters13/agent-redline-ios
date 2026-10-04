#if os(macOS) && REDLINE
import Foundation

/// A report as version 1 of the kit wrote it, before images were called snapshots: Tiny Tally's
/// growth card with an earlier state, a second screen and an attachment.
///
/// Copied from a real report in the hub's inbox, with the notes, the chat and the source path
/// replaced. Its keys (`images`, `picture`, `earlierState`), its file names and its lack of a
/// `version` are as the kit wrote them.
enum VersionOneReport {
    static let id = "20261004-162330"

    /// The image files it names, in the order the agent got them.
    static let files = ["screen-1-earlier-1.jpg", "screen-1.jpg", "screen-2.jpg", "note-5.jpg"]

    static let json = #"""
        {
         "app": {
          "build": "41",
          "bundleIdentifier": "com.markbuot.AthenaTracker",
          "name": "Tiny Tally",
          "sourceFile": "/w/TinyTally/App/TinyTallyApp.swift",
          "version": "1.0.9"
         },
         "createdAt": "2026-10-04T08:23:30Z",
         "destination": {
          "agent": "claude",
          "chat": "00000000-0000-4000-8000-000000000001",
          "title": "Growth card"
         },
         "device": {
          "model": "iPhone18,1",
          "systemName": "iOS",
          "systemVersion": "27.0.1"
         },
         "id": "20261004-162330",
         "items": [
          {
           "ancestors": [
            {
             "className": "AccessibilityNode",
             "frame": [[20, 211.66666666666669], [362, 495.00000000000006]],
             "identifier": "growth.card",
             "isContainer": true,
             "role": "Group"
            }
           ],
           "attachments": [],
           "createdAt": "2026-10-04T08:21:28Z",
           "element": {
            "className": "AccessibilityNode",
            "frame": [[40, 468.3333333333333], [322, 154.33333333333343]],
            "identifier": "growth.card.chart",
            "isContainer": true,
            "label": "Weight in kg by age",
            "role": "Group"
           },
           "kind": "element",
           "note": "The chart has no CDC range",
           "number": 1,
           "outline": {
            "height": 216,
            "width": 451,
            "x": 56,
            "y": 656
           },
           "picture": "screen-1-earlier-1.jpg",
           "screen": "screen-1",
           "screenTitle": "Patterns",
           "title": "Weight in kg by age"
          },
          {
           "ancestors": [],
           "attachments": [],
           "createdAt": "2026-10-04T08:21:59Z",
           "element": {
            "className": "AccessibilityNode",
            "frame": [[20, 156.33333333333326], [362, 295]],
            "identifier": "growth.card",
            "isContainer": true,
            "role": "Group"
           },
           "kind": "element",
           "note": "This needs a better empty state",
           "number": 2,
           "outline": {
            "height": 413,
            "width": 507,
            "x": 28,
            "y": 219
           },
           "picture": "screen-1.jpg",
           "screen": "screen-1",
           "screenTitle": "Patterns",
           "title": "growth.card"
          },
          {
           "ancestors": [],
           "attachments": [],
           "createdAt": "2026-10-04T08:22:14Z",
           "element": {
            "className": "AccessibilityNode",
            "frame": [[20, 156.33333333333326], [362, 295]],
            "identifier": "growth.card",
            "isContainer": true,
            "role": "Group"
           },
           "kind": "element",
           "note": "Same here",
           "number": 3,
           "outline": {
            "height": 413,
            "width": 507,
            "x": 28,
            "y": 219
           },
           "picture": "screen-1.jpg",
           "screen": "screen-1",
           "screenTitle": "Patterns",
           "title": "growth.card"
          },
          {
           "ancestors": [],
           "attachments": [],
           "createdAt": "2026-10-04T08:23:25Z",
           "element": {
            "className": "HostingScrollView",
            "frame": [[0, 170], [402, 46]],
            "identifier": "history.dates",
            "isContainer": true,
            "role": "Group"
           },
           "kind": "element",
           "note": "Add a light haptic while scrolling days",
           "number": 4,
           "outline": {
            "height": 64,
            "width": 563,
            "x": 0,
            "y": 238
           },
           "picture": "screen-2.jpg",
           "screen": "screen-2",
           "screenTitle": "History",
           "title": "history.dates"
          },
          {
           "ancestors": [],
           "attachments": ["note-5.jpg"],
           "createdAt": "2026-10-03T20:52:05Z",
           "kind": "screen",
           "note": "Same bug in another app",
           "number": 5,
           "screenTitle": "Today",
           "title": "Today"
          }
         ],
         "screens": [
          {
           "id": "screen-1",
           "images": [
            {
             "earlierState": true,
             "file": "screen-1-earlier-1.jpg",
             "height": 1224,
             "notes": [1],
             "part": 1,
             "parts": 1,
             "stitchedFrom": 1,
             "width": 563
            },
            {
             "earlierState": false,
             "file": "screen-1.jpg",
             "height": 1224,
             "notes": [2, 3],
             "part": 1,
             "parts": 1,
             "stitchedFrom": 1,
             "width": 563
            }
           ],
           "notes": [1, 2, 3],
           "title": "Patterns",
           "viewController": "NavigationStackHostingController"
          },
          {
           "id": "screen-2",
           "images": [
            {
             "earlierState": false,
             "file": "screen-2.jpg",
             "height": 1224,
             "notes": [4],
             "part": 1,
             "parts": 1,
             "stitchedFrom": 1,
             "width": 563
            }
           ],
           "notes": [4],
           "title": "History",
           "viewController": "NavigationStackHostingController"
          }
         ]
        }
        """#

    static let markdown = #"""
        # UI report: Tiny Tally 1.0.9 (41)

        iPhone18,1, iOS 27.0.1. 5 notes on 2 screens. Numbers match the red numbered outlines in the pictures.

        ## Screen: Patterns

        One screenshot of this screen: screen-1.jpg. Notes 2 and 3 are outlined and numbered on it.
        An earlier state of the same screen, before its content changed: screen-1-earlier-1.jpg, with note 1.

        1. **Weight in kg by age** (Group, identifier `growth.card.chart`): The chart has no CDC range. See screen-1-earlier-1.jpg.
        2. **growth.card** (Group, identifier `growth.card`): This needs a better empty state. See screen-1.jpg.
        3. **growth.card** (Group, identifier `growth.card`): Same here. See screen-1.jpg.

        ## Screen: History

        One screenshot of this screen: screen-2.jpg. Note 4 is outlined and numbered on it.

        4. **history.dates** (Group, identifier `history.dates`): Add a light haptic while scrolling days. See screen-2.jpg.

        ## Attachments

        5. **Today**: Same bug in another app. Images: note-5.jpg.
        """#
}
#endif
