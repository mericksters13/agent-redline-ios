# iOSAgenticDebuggingKit

Report UI issues from an iPhone straight into the coding agent chat that is working on the app.

Tap the floating debugger button, tap the broken elements, add notes, and send. The report lands in the active agent chat for that app's project.

Screenshots work too. Take one as usual and send it from the thumbnail that slides in, or in pick mode use the capture button to attach the screen as it is, or the paperclip to attach photos. Element notes and attachments travel together in one report. Each screen arrives as one screenshot with every note on it outlined and numbered; a screen you scrolled while noting is stitched into one tall screenshot (only a very long one is split, between sections, into labeled parts), and `report.md` tells the agent which picture shows each note.

Setup in the app is one line, `.agenticDebugging()` on the app's root view. The kit needs no Info.plist keys, permissions or build settings. On a physical iPhone, iOS asks once per app for local network access the first time a report is sent, with its standard wording; an app may add `NSLocalNetworkUsageDescription` to explain it in its own words, but doesn't need to. In apps that already declare Photos use, the paperclip's Photos grid can ask for access, only when you tap Show recent photos; with access, the kit also offers screenshots taken in other apps. Apps without it get the system photo picker.

Status: early development. Debug builds only.

## Mac setup

Reports reach a chat only through the `agentic-debugging` tool on the Mac. Without it, Send keeps the report on the phone. Set it up once per Mac:

1. Build the tool and put it on your `PATH`:

   ```sh
   swift build -c release --product agentic-debugging
   cp .build/release/agentic-debugging /usr/local/bin/
   ```

2. Run `agentic-debugging setup`. It makes sure the `claude` command is signed in so it can start new Claude Code chats, and adds the hooks Codex and Cursor need. In Codex, open `/hooks` and trust "Report delivery".

3. Start the hub, which takes reports off phones and simulators. Add `agentic-debugging mcp` as an MCP server in your agent, so every chat starts it when needed, or run `agentic-debugging hub` yourself.

`agentic-debugging status` shows what the hub is doing and what is waiting in the inbox. `agentic-debugging remove` takes the hooks out again.

## Parts

- iOS Swift package: floating debugger button, element picker, annotations, glance bubble and full chat.
- Mac tool (`agentic-debugging`): the hub that finds paired phones over Bonjour, stores reports and conversations, and routes them to agent chats.
- MCP server (`agentic-debugging mcp`): lets any MCP-capable agent receive reports.
