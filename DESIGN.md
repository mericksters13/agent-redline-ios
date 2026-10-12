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

The demo serves developers trying annotation, component selection, and layout inspection. Keep navigation labels literal and brief, using the existing Recipes, Tonight, Plan, and UIKit tabs as the pattern. Layout names the sample screen; Padding, Layout and Hierarchy name the note card's header controls. Explain the next action in plain language, and keep experimental or unavailable results accurate. Preserve the existing sample instructions and physical edge names rather than adding setup terms to navigation.

This wording follows the app's current [demo screens and actions](Examples/RedlineDemo/README.md), the [layout inspector's supported behavior](Examples/RedlineDemo/LAYOUT-PROTOTYPE.md), and the native overlay conventions recorded here.

## Colors

The palette belongs to the overlay, while captured host content keeps its original appearance. The frontmatter records the shared colors from `Mono.swift`.

### Primary

- White controls identify primary actions and what is chosen: an open header control, an included padding edge, the selected hierarchy row. Their labels turn black.
- Red is semantic markup: element outlines, drawing strokes, saved markers, included padding bands, a dashed included frame, and the dot on a header control whose closed panel holds something included. Destructive actions also use red. Use the native semantic color in its existing context rather than creating a brand accent.

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

The annotation form keeps the element's name and the note field at its top and its actions in a fixed footer. One panel at a time opens between them and scrolls by itself, so the name and the note stay in place. Constrained height, landscape and larger text must keep Cancel and the primary action reachable. Accessibility text sizes change layout rows to vertical stacks and arrange padding edge controls in a two-column grid. Physical edge names remain Top, Right, Bottom and Left.

There is no shared spacing scale or breakpoint system in these sources. Reuse the native component's measured layout instead of deriving global tokens from individual dimensions.

## Elevation & Depth

Opaque black surfaces, faint white boundaries and inset fills distinguish controls from the host. Soft black shadows separate floating panels, capsules and hints from the app underneath. They are structural, without decorative hard offsets. Continuous clipping contains previews and panel content.

## Shapes

Panels use broad continuous rounded corners; note fields use smaller continuous corners. Compact preview beds and element outlines share the compact radius. Capsules hold primary text actions, the top control group and the padding edge controls; circles hold icon controls and note numbers. Preserve these native shapes rather than substituting a single radius for every component.

Frontmatter radius values are portable representations of the recurring native point values, not a scale for host-app layout measurements.

## Components

### Buttons

Primary actions are white capsules with black semibold text. Secondary icon controls use white symbols on the inset fill. Cancel is a quieter text action. Native controls carry accessible action names and touch areas of at least 44 points even when the visible shape is smaller.

### Inputs / Fields

The note field uses body text, a white insertion tint, an inset fill and continuous corners. It grows across multiple lines. Inline errors sit near the fixed footer where the failed action occurred.

### Cards / Containers

The note card and notes list share black surfaces, broad corners, a faint boundary and a soft shadow. The note header identifies the chosen element with its name, role and numbered badge, and with its measured size when its layout was read. Round header controls open one panel at a time under the note field.

### Navigation

The compact top capsule groups close, screen context, note count and annotation actions. The available primary Send action uses the white capsule treatment. Labels and SF Symbols retain the same native hierarchy as the form.

### Note card panels

The note card opens with the note field focused under the element's name. Round controls at the header's trailing edge, in the same circles as the top capsule's icons, each open one panel under the note field: Padding, Layout and Hierarchy. An open control turns white. Opening a panel lowers the keyboard, and returning to the note field closes the panel. Cancel and the primary action stay in the footer in every state.

Padding and Layout appear only for an element whose layout was verified. An element without a verified match shows neither control and no status text, so its card is the plain note card.

Nothing is included in a note until it is chosen. A caption line at the foot of an open panel names what is included, such as "Included in the note: left padding and frame." While a panel is closed, a red dot on its control says something in it is included. The notes list ends a note's caption with the same words, such as "with left padding".

### Padding

The Padding panel crops only the selected component and its measured padding. Neutral shading marks measured padding and red outlines the content. One capsule control per edge names the edge and its value, with Top and Bottom above and below the crop and Left and Right beside it. A control turns white when its edge is included, and that edge's band turns red in the crop. An edge with no padding stays selectable in a quieter color. Touch areas remain at least 44 points in both dimensions.

At accessibility text sizes, the crop stays above a two-column grid of edge controls.

### Layout

The Layout panel lists the component's own frame, stack and priority settings and then its parents' settings, one row each. A row's leading circle fills with a check mark when the row is included. The component's own padding has no row; it is chosen edge by edge in the Padding panel.

### Included marks

What is included is also drawn on the captured screen behind the card: each included padding band shaded red, an included frame as a dashed red box, and one black tag with their values on the side of the element away from the card.

### Hierarchy

The Hierarchy panel opens under the note field. The header keeps naming the selected element as the selection moves. An up row above the tree shows one more enclosing element and what it holds. Rows show each element's role after its name. Press briefly, then drag across rows to move the selection and host outline with the finger. Ordinary swipes scroll; taps select, and branch chevrons expand or collapse children. During traversal, the card stays anchored and clipped or collapsed rows cannot become the target.

These are prototype behaviors, scoped to verified text, control, image, and stack matching.

## Do's and Don'ts

### Do:

- Do reuse the Mono colors and native text styles.
- Do keep the host screen visible around compact overlay panels.
- Do keep form actions reachable while long content scrolls.
- Do pair an included padding edge with a white control, a red band in the crop, a red band on the captured screen and the caption line.
- Do keep the name, the note field and the footer in place whatever panel is open.
- Do retain accessibility labels, selected values and adequate touch areas.

### Don't:

- Don't introduce a custom brand palette or blue controls.
- Don't add decorative metaphors or uppercase label rows.
- Don't make host-capture colors part of Redline's palette.
- Don't treat illustrative panel samples or the opt-in layout prototype as evidence of native runtime behavior.
