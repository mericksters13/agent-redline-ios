# iOSAgenticDebuggingKit

Report UI issues from an iPhone straight into the coding agent chat that is working on the app.

Tap the floating debugger button, tap the broken elements, add notes, and send. The report lands in the active agent chat for that app's project, and the agent can reply on the phone.

Screenshots work too. Take one as usual and send it from the thumbnail that slides in, or use the paperclip in pick mode to attach the current screen or recent screenshots. Element notes and attachments travel together in one report.

Setup is one line, `.agenticDebugging()` on the app's root view. The kit needs no Info.plist keys, permissions or build settings. When the app already has Photos access for its own reasons, the kit also offers screenshots taken in other apps; it never asks for that access.

Status: early development. Debug builds only.

## Parts

- iOS Swift package: floating debugger button, element picker, annotations, glance bubble and full chat.
- Mac hub (Node): finds paired phones over Bonjour, stores reports and conversations, routes them to agent chats.
- MCP server: lets any MCP-capable agent receive reports and message the phone.
