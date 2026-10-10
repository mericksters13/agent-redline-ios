---
name: Redline
description: Compact native iOS overlays for reporting screen issues.
colors:
  surface: "#000000"
  text: "#ffffff"
  secondary: "rgb(255 255 255 / 0.6)"
  fill: "rgb(255 255 255 / 0.12)"
  hairline: "rgb(255 255 255 / 0.16)"
typography:
  title:
    fontFamily: "San Francisco"
    fontWeight: 600
  body:
    fontFamily: "San Francisco"
    fontWeight: 400
  label:
    fontFamily: "San Francisco"
    fontWeight: 400
rounded:
  panel: "24px"
  field: "12px"
  compact: "8px"
components:
  button-primary:
    backgroundColor: "{colors.text}"
    textColor: "{colors.surface}"
    typography: "{typography.title}"
  button-secondary:
    backgroundColor: "{colors.fill}"
    textColor: "{colors.text}"
    typography: "{typography.title}"
  note-field:
    backgroundColor: "{colors.fill}"
    textColor: "{colors.text}"
    typography: "{typography.body}"
    rounded: "{rounded.field}"
  panel:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.text}"
    rounded: "{rounded.panel}"
  padding-control:
    typography: "{typography.label}"
  padding-control-selected:
    textColor: "{colors.text}"
    typography: "{typography.label}"
---

# Design System: Redline

## Overview

**Creative North Star: "Black and white system style"**

Redline uses a compact native iOS overlay language: black panels, white controls and system typography. Its surfaces keep the same appearance over light and dark host apps, so the tool remains visually distinct from the screen being inspected.

This records the existing on-device system. The captured-component layout form inherits it as an opt-in Debug prototype; its experimental composition does not establish a new identity or promise general layout inspection.

**Key Characteristics:**

- Black surfaces and white type over any host app.
- Native text styles, meaningful symbols and continuous corners.
- Compact panels with reachable actions when content scrolls.
- Red carries annotation and selection meaning.

## Demo wording

The demo serves developers trying annotation, component selection, and layout inspection. Keep navigation labels literal and brief, using the existing Recipes, Tonight, Plan, and UIKit tabs as the pattern. Layout names the sample screen; Padding & frame names the inspector disclosure when measured padding exists, and Frame names it otherwise. Explain the next action in plain language, and keep experimental or unavailable results accurate. Preserve the existing sample instructions and physical edge names rather than adding setup terms to navigation.

This wording follows the app's current [demo screens and actions](Examples/RedlineDemo/README.md), the [layout inspector's supported behavior](Examples/RedlineDemo/LAYOUT-PROTOTYPE.md), and the native overlay conventions recorded here.

## Colors

The palette belongs to the overlay, while captured host content keeps its original appearance. The frontmatter records the shared colors from `Mono.swift`.

### Primary

- White controls identify primary actions. Their labels turn black. Selected padding values turn white while their dimension lines remain red.
- Red is semantic markup: element outlines, drawing strokes, saved markers, tappable padding dimension lines and selected padding bands. Destructive actions also use red. Use the native semantic color in its existing context rather than creating a brand accent.

### Neutral

- **Surface:** black panels, capsules and floating controls.
- **Text:** white primary content and symbols.
- **Secondary:** softer explanations, metadata and secondary actions.
- **Fill:** inset fields, preview beds and secondary controls.
- **Hairline:** subtle panel and control boundaries.

**The Overlay Identity Rule.** Keep Redline's black and white surfaces consistent across host color schemes. Host content inside captures retains its own colors.

## Typography

San Francisco is supplied by native system fonts. Frontmatter records the recurring family and weights; native text styles determine size and scaling.

- **Title:** subheadline with semibold weight for element names and primary actions.
- **Body:** body for the multiline note field.
- **Label:** caption for roles, measurements and supporting context; measured values use semibold weight, bold when selected, and monospaced digits.
- Footnote supports brief hints and inline errors. SF Symbols communicate actions with accessible labels.

**The Native Type Rule.** Use native text styles and allow Dynamic Type to change the layout; do not replace them with fixed visual sizes.

## Layout

Panels use content-driven vertical stacks with left-aligned text and compact groups. The host screen remains visible around them. The top control capsule sits below the safe area; annotation panels are positioned within available screen and keyboard space.

The annotation form separates scrolling content from its action footer. Constrained height, landscape and larger text must keep Cancel and the primary action reachable. Accessibility text sizes change measurement rows to vertical stacks and arrange padding dimension controls in a two-column grid. Physical edge names remain Top, Right, Bottom and Left.

There is no shared spacing scale or breakpoint system in these sources. Reuse the native component's measured layout instead of deriving global tokens from individual dimensions.

## Elevation & Depth

Opaque black surfaces, faint white boundaries and inset fills distinguish controls from the host. Soft black shadows separate floating panels, capsules and hints from the app underneath. They are structural, without decorative hard offsets. Continuous clipping contains previews and panel content.

## Shapes

Panels use broad continuous rounded corners; note fields use smaller continuous corners. Compact preview beds and element outlines share the compact radius. The prototype's padding dimension controls use lines with end ticks and invisible rectangular touch areas, without tile fills or rounded control surfaces. Capsules hold primary text actions and the top control group; circles hold icon controls and note numbers. Preserve these native shapes rather than substituting a single radius for every component.

Frontmatter radius values are portable representations of the recurring native point values, not a scale for host-app layout measurements.

## Components

### Buttons

Primary actions are white capsules with black semibold text. Secondary icon controls use white symbols on the inset fill. Cancel is a quieter text action. Native controls carry accessible action names and touch areas of at least 44 points even when the visible shape is smaller.

### Inputs / Fields

The note field uses body text, a white insertion tint, an inset fill and continuous corners. It grows across multiple lines. Inline errors sit near the fixed footer where the failed action occurred.

### Cards / Containers

The note card and notes list share black surfaces, broad corners, a faint boundary and a soft shadow. The note header identifies the chosen element with its name, role and numbered badge. Disclosure controls reveal additional context progressively.

### Navigation

The compact top capsule groups close, screen context, note count and annotation actions. The available primary Send action uses the white capsule treatment. Labels and SF Symbols retain the same native hierarchy as the form.

### Captured component and padding measurements

The larger, unfilled layers symbol beside the component name opens the existing hierarchy flow. The control has no visible container. It is distinct from the chevrons that expand and collapse content. Press briefly, then drag across hierarchy rows to move the selection and host outline with the finger. Ordinary swipes scroll; taps select, and branch chevrons still expand or collapse children. During traversal, the panel stays anchored and clipped or collapsed rows cannot become the target.

Padding & frame groups the component snapshot and red measurement lines under a native disclosure. The disclosure clips its content during height changes to keep the outgoing preview from drawing over adjacent form rows. A compact padding and size summary stays in its header. The preview starts collapsed and remembers the choice during the session. Included in note and the written note stay outside this disclosure, so collapsing it preserves both the selected context and the draft.

The opt-in Debug layout form crops only the selected component and its measured padding inside the note card. Surrounding container and frame space are excluded from the crop. Neutral shading marks measured padding, red outlines the content and red shading marks selected edges. Frame dimensions, or captured size when a frame is unavailable, remain text below the preview.

Tappable red dimension lines have end ticks, with Top and Bottom above and below the crop and Left and Right close beside it. Each control shows its physical edge name and measured value. Selection thickens the red line, turns its value white and bold, shades the captured padding band red and adds visible context under Included in note. The visible lines have no tiles; their invisible rectangular touch areas remain at least 44 points in both dimensions.

At accessibility text sizes, the crop stays above a two-column measurement grid. Without measured padding, omit the grid, edge labels, and unavailable-padding placeholder; keep the crop and available dimensions under Frame. Layout and parent details remain disclosures. These are prototype behaviors, scoped to verified text, control, image, and stack matching and honest unavailable or ambiguous results.

## Do's and Don'ts

### Do:

- Do reuse the Mono colors and native text styles.
- Do keep the host screen visible around compact overlay panels.
- Do keep form actions reachable while long content scrolls.
- Do pair selected padding with a thicker red dimension line, a white value, a shaded red edge and visible note context.
- Do retain accessibility labels, selected values and adequate touch areas.

### Don't:

- Don't introduce a custom brand palette or blue controls.
- Don't add decorative metaphors or uppercase label rows.
- Don't make host-capture colors part of Redline's palette.
- Don't treat illustrative panel samples or the opt-in layout prototype as evidence of native runtime behavior.
