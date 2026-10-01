# iOSAgenticDebuggingKit

Report UI issues from an iPhone straight into the coding agent chat that is working on the app.

Knock twice on the back of the phone, tap the broken elements, add notes, and send. The report lands in the active agent chat for that app's project, and the agent can reply on the phone.

Status: early development. Debug builds only.

## Parts

- iOS Swift package: knock trigger, element picker, annotations, glance bubble and full chat.
- Mac hub (Node): finds paired phones over Bonjour, stores reports and conversations, routes them to agent chats.
- MCP server: lets any MCP-capable agent receive reports and message the phone.
