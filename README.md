# PiDesk

Native macOS SwiftUI frontend for local Pi and Pi running on remote SSH hosts. The original mockup's layout and styling are retained, with real RPC-backed state replacing the sample conversations.

## Run

Requires macOS 13+, a current Pi installation, and Node.js on each client host. Building requires Swift 5.9+; the tests use Swift Testing (Swift 6+).

```sh
swift run PiDesk
```

Authenticate using Pi in a terminal (`pi`, then `/login`) on each host. PiDesk uses those credentials and Pi's existing settings. Configure the Pi executable and project directory in the client's **••• → Edit client** menu. Changing the directory disconnects that client's conversations and moves them to the new directory. Existing persisted conversations are forked on their next connection, preserving the active history while giving the new Pi session the new working directory.

For remote clients, enter an SSH config alias or `user@hostname` and a port. First connect from Terminal to verify the host key and configure key/agent authentication. PiDesk uses batch-mode SSH with strict host-key checking; it does not prompt for passwords or accept unknown keys automatically. Remote hosts must provide a POSIX-compatible shell.

PiDesk starts its own `pi --mode rpc` process for each open conversation. It does **not** attach to an existing terminal Pi process. Do not open the same session file concurrently in another application.

## Implemented

- Local stdio and remote SSH RPC transports, real connection status and errors.
- Independent conversations, streaming text/thinking, expandable tool calls/results.
- Model and supported thinking-level selection from Pi's actual catalog.
- Steering messages during generation; Stop/Escape clears and restores queued messages before aborting.
- New conversations, rename, context compaction, session info/usage, copy, Markdown transcript export.
- Read-only discovery of saved Pi sessions on each host and resuming their active branch.
- Extension confirmation, selection, input, and editor dialogs; notifications, status text, and text widgets.
- Client management and persisted session references/drafts.

**⌘⇧N** creates a conversation; **⌘Return** sends; **⌘,** opens Settings. Client and conversation menus expose additional actions.

Pi can execute tools with the permissions of the host account. PiDesk does not add a sandbox or automatically approve project trust. Disconnecting or quitting stops the GUI-owned processes; remote jobs are not a durable background service.

## Storage

Pi owns conversation history on each host, normally in `~/.pi/agent/sessions/`. PiDesk stores profiles, session references, and drafts in:

```
~/Library/Application Support/PiDesk/workspace.json
```

Closing conversations/removing clients does not delete Pi's session files. An unreadable workspace is not overwritten. For an isolated development workspace, launch with `PIDESK_WORKSPACE=/absolute/path/workspace.json`.

## Verification

```sh
scripts/test.sh
PIDESK_TEST_REAL_PI=1 scripts/test.sh --filter realPiHandshakeWithoutModelCalls
swift build
```

The test script handles the Swift Testing framework paths omitted by some Command Line Tools installations, without changing `xcode-select`. A macOS 13 deployment-target warning from the macOS 14+ test framework is expected on the current toolchain; it does not affect the application build.

Tests cover framing/Unicode, RPC correlation/errors/timeouts/exits, streamed message assembly, tool deduplication, model/thinking controls, queue restoration, extension confirmations, session isolation, reconnect, compaction, quoting, and workspace persistence. The opt-in real-Pi test performs protocol queries only—no model/API call.

See [TODO.md](TODO.md) for remaining work and verification gaps.
