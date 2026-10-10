---
version: 1
slug: "sources-redline-layoutsnapshotview-swift"
primary_target: "Sources/Redline/LayoutSnapshotView.swift"
related_targets: ["Sources/Redline/LayoutInspectorView.swift"]
---

# Captured component layout form

Scope: DEV-45's opt-in Debug layout prototype inside the annotation form. Mode: Operate.

Audience and job: a tester selects a supported text component, inspects its captured padding and frame, and includes selected measurements in a note. Preserve runtime provenance, unavailable states, the existing note workflow, Dynamic Type, and reachable form actions.

## Direction contract

THESIS: Turn measured padding into tappable red dimension lines beside a captured component.

OWN-WORLD: Preserve Redline's black form, white native system text, and red annotation meaning. End ticks distinguish measurement spans from the content outline.

STORY: The tester taps a measurement line, sees its padding highlighted, and saves that value with the note. Another tap removes it.

FIRST VIEWPORT: Crop only the component and its padding. Left and Right dimensions sit close beside the crop; Top and Bottom remain above and below. Frame size and included context appear below; form actions remain reachable.

FORM: User-pinned storyboard-style dimension lines replace the prototype's edge tiles. This precisely specified refinement preserves the existing system style; no concept roll or generated comp applies.

FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance
