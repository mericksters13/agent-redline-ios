---
version: 1
slug: "sources-iosagenticdebuggingkit-overlayview-swift"
primary_target: "Sources/iOSAgenticDebuggingKit/OverlayView.swift"
related_targets: ["Sources/iOSAgenticDebuggingKit/DebugSession.swift"]
---

# Debugger overlay

Scope: the on-device overlay (floating button, pick-mode title block, element callouts, note slip, notes list, toast). Mode: Operate.

Audience and job: developers, designers and QA testers mid-test on a real iPhone, calling out broken elements with a short note and sending the set. Constraints: sits over any host app, light or dark; must cover as little of it as possible; plain language; iOS touch targets, Dynamic Type, Reduce Motion.

Memorable moment: the callout draws itself, a leader line running from the picked element to its numbered balloon.

## Direction contract

THESIS: Notes are part callouts on an engineering drawing: numbered balloons on leader lines point at real elements. Refuses the translucent capsule with system-blue outlines over a dimmed screen.

OWN-WORLD: Graphite ink #111418, drafting white #F7F8F6, one revision orange #FF5A1F, construction gray #8A9099. Hairline rules, compartment cells, balloon circles, corner ticks, a sheet border. SF Pro with tabular figures and small uppercase cell labels.

STORY: The app becomes a drawing sheet; the tester calls out the broken part, writes one line, and sends the set.

FIRST VIEWPORT: Pick mode. A thin orange sheet border at the display edge; an ink title block at top with close, screen name, note count and Send; corner ticks on the element under the finger; saved notes as balloons on leaders. No dimming.

FORM: Drawing Balloons, rank 1 of 7, seed 74ea7de9 (pick).

FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance
