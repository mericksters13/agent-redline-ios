---
version: 1
slug: "sources-redline-layoutsnapshotview-swift"
primary_target: "Sources/Redline/LayoutSnapshotView.swift"
related_targets: ["Sources/Redline/LayoutInspectorView.swift", "Sources/Redline/OverlayView.swift"]
---

# Captured component layout form

Scope: DEV-45's opt-in Debug layout prototype inside the annotation form, as DEV-47 arranged it. Mode: Operate.

Audience and job: a tester selects a supported component, writes a note, and includes the padding edges and layout rows they choose. Preserve runtime provenance, unavailable states, the existing note workflow, Dynamic Type, and reachable form actions.

## Direction contract

THESIS: Let the tester choose what a note includes, on a captured component large enough to tap.

OWN-WORLD: Preserve Redline's black form, white native system text, and red annotation meaning. White marks what is chosen in the card; red marks it on the capture.

STORY: The tester opens Padding, taps a side, sees its band turn red in the crop and on the screen, and saves that value with the note. Another tap removes it.

FIRST VIEWPORT: The note card with its note field focused. Round header controls open Padding, Layout and Hierarchy one at a time under the note. Padding crops only the component and its padding, with one capsule control per side: Left and Right beside the crop, Top and Bottom above and below. Layout lists the frame and parent settings as rows to include. A caption names what is included; form actions remain reachable.

FORM: User-approved capsule edge controls and header controls (DEV-47) replace the storyboard-style dimension lines and the disclosure rows, which had replaced the prototype's edge tiles. They stay inside the existing system style; no concept roll or generated comp applies.

FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance
