---
version: 1
slug: "sources-iosagenticdebuggingkit-overlayview-swift"
primary_target: "Sources/iOSAgenticDebuggingKit/OverlayView.swift"
related_targets: ["Sources/iOSAgenticDebuggingKit/DebugSession.swift"]
---

# Debugger overlay

Scope: the on-device overlay (floating button, pick-mode capsule, element highlight, note card, notes list, toast). Mode: Operate.

Audience and job: developers, designers and QA testers mid-test on a real iPhone, calling out broken elements with a short note and sending the set. Constraints: sits over any host app, light or dark; must cover as little of it as possible; plain language; iOS touch targets, Dynamic Type, Reduce Motion.

Memorable moment: the black capsule settles under the status bar like a system control, and the app stays fully visible underneath.

## Direction contract

THESIS: The debugger looks like part of iOS itself: black surfaces, white type, nothing else unless it means something. Refuses brand palettes, blue, and decorative metaphors.

OWN-WORLD: Pure black panels with a faint white hairline, white primary text, white at 60% for secondary text, white at 12% for fields and secondary buttons, red only for delete. SF Pro at system text styles, SF Symbols, continuous corners.

STORY: The tester taps the button, touches the broken element, writes one line, and sends.

FIRST VIEWPORT: Pick mode. A black capsule under the status bar with close, the screen name, the note count and a white Send button; a white-on-black outline and a black name tag on the element under the finger. Nothing dims the app.

FORM: User-pinned black and white system style, replacing Drawing Balloons (seed 74ea7de9).

FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance
