# Redline

Point at UI on an iPhone, add a note, and send it straight into the coding agent chat working on the app. Redline is not a debugger: it marks up what you see, the way a designer redlines a screen, and hands that to the agent.

Tap the floating Redline button, tap the broken elements, add notes, and send. The report lands in the agent chat you picked for that app.

Screenshots work too. Take one as usual and send it from the thumbnail that slides in, or in pick mode use the capture button to attach the screen as it is, or the paperclip to attach photos. Element notes and attachments travel together in one report. Each screen arrives as one screenshot with every note on it outlined and numbered; a screen you scrolled while noting is stitched into one tall screenshot (only a very long one is split, between sections, into labeled parts), and `report.md` tells the agent which picture shows each note.

Setup is one line: add the `Redline` package and put `.redline()` on the app's root view. The kit needs no Info.plist keys, permissions or build settings. In apps that already declare Photos use, the paperclip's Photos grid can ask for access, only when you tap Show recent photos; with access, the kit also offers screenshots taken in other apps. Apps without it get the system photo picker.

Status: early development. Debug builds only.

## Parts

- `Redline`, the iOS Swift package: the floating Redline button, element picker, notes and attachments.
- Redline, the Mac menu bar app: takes reports off paired phones and simulators and hands each one to the agent chat picked on the phone. The `redline` command does the same from Terminal.
- MCP server (`redline mcp`): lets a Claude Code or Codex chat receive reports.
