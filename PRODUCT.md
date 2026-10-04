# Product

<!-- impeccable:product-schema 1 -->

## Platform

ios

## Users

iOS developers, designers, and QA testers checking a Debug build of an app on a real iPhone. They find something wrong on screen and want to point at the exact element and get it, with a note, to the coding agent working on that app. Designers and QA testers use it too, so nothing in it may assume coding knowledge.

## Product Purpose

Replace the screenshot, AirDrop, and paste loop with pointing at the broken element on the phone. A report carries each element's details, a screenshot with the element outlined, and a note, and lands in the agent chat already working on that app's project. The agent can answer back on the phone. Success: reporting an issue takes seconds and the agent can find the exact view without guessing.

## Positioning

It points at real elements in the app's view hierarchy rather than drawing on screenshots, and it delivers into the agent chat already working on the app, with Claude Code or Codex.

## Operating Context

Used mid-test, one-handed, on a physical iPhone, on top of whatever app is being tested (light or dark, any brand). The person keeps navigating the app between notes, collects several notes across screens, then sends them together. Agent replies arrive later as a glance bubble or a full chat.

## Capabilities and Constraints

- A debug-only Swift package attached once at the app root. Release and TestFlight builds compile it out.
- Lives in its own window above the host app. Annotation screenshots are taken from the app's windows only, so Redline never appears in them.
- Element details come from the accessibility tree; SwiftUI exposes roles, labels, and identifiers, not source file names.
- Confirmed structure: a draggable floating button that snaps to screen edges opens pick mode; pick-mode controls sit in a top island; the note box opens next to the picked element; a review tray lists waiting notes.
- A double knock on the back was tried and dropped because it could not be told apart from normal taps.
- Built on the Mac: Redline, the menu bar app and `redline` command that take reports off paired phones and simulators and hand each to the agent chat picked on the phone, and the MCP server. Designed but not built: the glance bubble and full chat for agent replies on the phone.

## Brand Commitments

- Black and white minimalism that looks system-level, in the family of the Dynamic Island and system overlays. No custom brand palette.
- No blue anywhere. Other colors only where they carry meaning, such as red for delete.
- No decorative metaphors, uppercase label rows, or invented ornament.
- It must read as a tool on top of the app, never as part of the app being tested.
- It must cover as little of the app as possible, since the app's UI is what is being reported on.

## Evidence on Hand

Real host apps for testing: Tiny Tally and Trail. No users, metrics, or testimonials exist yet.

## Product Principles

- The app under test is the subject; Redline stays out of its way.
- Point, note, send: every extra step is a cost.
- Speak plainly, so a designer or QA tester never needs to know the code.
- Never mistakable for the host app.

## Accessibility & Inclusion

No product-specific standard was set. Controls follow iOS minimum touch targets and support Dynamic Type and VoiceOver labels where practical.
