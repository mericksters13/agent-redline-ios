# ``Redline``

Point at UI on an iPhone, add a note, and send it to the coding agent chat working on the app.

## Overview

Redline marks up what you see, the way a designer redlines a screen. Tap the floating
button, tap the elements that look wrong, write a note for each, and send. The report
lands in the agent chat you picked for the app, with one snapshot per screen and every
note outlined and numbered on it.

### Set up the app

Add the `Redline` package to the app and attach the modifier once, at the root view:

```swift
import Redline
import SwiftUI

@main
struct ExampleApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .redline()
        }
    }
}
```

The kit needs no Info.plist keys, permissions or build settings. In apps that already
declare Photos use, the photo grid can ask for access when you tap Show recent photos.
Other apps get the system photo picker, which needs no permission.

### Set up the Mac

Reports go to the Mac through Redline's Mac menu bar app, or the `redline` command built
from the same package. It takes reports off paired phones and simulators and hands each
one to the Claude Code or Codex chat picked on the phone.

### Release builds

Everything in the kit compiles only in Debug builds. In Release builds, including
TestFlight, ``SwiftUICore/View/redline(sourceFile:)`` returns the view unchanged: there is
no overlay, no private API and no permission prompt, and the caller's file path is not
kept in the binary.

## Topics

### Adding Redline

- ``SwiftUICore/View/redline(sourceFile:)``
