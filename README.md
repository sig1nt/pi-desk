# PiDesk

Native macOS SwiftUI frontend for local Pi and Pi running on remote SSH hosts. The original mockup's layout and styling are retained, with real RPC-backed state replacing the sample conversations.

## Run

Requires macOS 13+, a current Pi installation, and Node.js on each client host. Building requires Swift 6.4+ and Xcode (SwiftUI's macro plugin is not included in the standalone Command Line Tools).

```sh
swift run PiDesk
```

Build a local, ad-hoc-signed app (with bundled SwiftPM resources):

```sh
scripts/build-app.sh            # dist/PiDesk.app
scripts/build-app.sh --install  # also installs to ~/Applications/PiDesk.app
```

Quit PiDesk before replacing an installed copy. The script does not launch the app, run tests, or notarize it. Finder launch still needs manual verification. Client processes use login shells plus common fallback PATH entries; set a full Pi executable path if your installation is not found.

Authenticate using Pi in a terminal (`pi`, then `/login`) on each host. PiDesk uses those credentials and Pi's existing settings. Configure the Pi executable and project directory in the client's **••• → Edit client** menu. Changing the directory disconnects that client's conversations and moves them to the new directory. Existing persisted conversations are forked on their next connection, preserving the active history while giving the new Pi session the new working directory.

For remote clients, enter an SSH config alias or `user@hostname` and a port. First connect from Terminal to verify the host key and configure key/agent authentication. PiDesk uses batch-mode SSH with strict host-key checking; it does not prompt for passwords or accept unknown keys automatically. Remote hosts must provide a POSIX-compatible shell.

PiDesk starts its own `pi --mode rpc` process for each open conversation. It does **not** attach to an existing terminal Pi process. A Node supervisor holds a host-side `<canonical-session-path>.pidesk-lock` directory until its Pi process exits, including while closing/reopening. Local profiles, symlinks, and SSH aliases that resolve to the same file share this lock. A busy session refuses to open; retry after its previous process finishes.

These are **advisory PiDesk locks**: terminal Pi and other applications do not honor them. Do not open the same session file concurrently elsewhere. After a crash, a lock may remain; inspect its `owner.json` on the host and confirm that no writer is running before manually removing that lock directory. PiDesk never automatically steals stale locks.

## Implemented

- Local stdio and remote SSH RPC transports, real connection status and errors.
- Independent conversations, streaming text/thinking, expandable tool calls/results.
- Paste images with ⌘V (or the image button), preview/remove them before sending, and render image messages in the transcript.
- Model and supported thinking-level selection from Pi's actual catalog.
- Composer completion for `@` project paths on the connected local/SSH client and for extension, prompt-template, and skill slash commands reported by that Pi RPC session.
- Steering messages during generation; Stop/Escape clears and restores queued messages before aborting.
- New conversations, rename, context compaction, session info/usage, copy, Markdown transcript export including thinking, tool arguments/results, and supported inline images. **Export full Pi history** saves raw entries from all branches as JSON (not an importable Pi JSONL session).
- Cancellable, read-only saved-session discovery with progress, bounded parallel reads, and metadata reuse on refresh. Set **Session directory** in Edit client for custom `--session-dir` storage (also used for new conversations). Without it, discovery follows the host's Pi environment/defaults.
- Extension confirmation, selection, input, and editor dialogs; notifications, status text, and text widgets.
- Client management and persisted session references/drafts.
- Persistent delivery-unknown recovery: timed-out/interrupted submissions are kept separately and block sending until explicitly discarded or restored for manual resend. Reconnect never automatically resubmits them.
- Geometry-driven follow-bottom scrolling, including tool/thinking expansion, with a jump-to-latest control.
- Common Markdown tables, nested/ordered/task lists, headings, quotes, and code fences; supported embedded image blocks render as bounded thumbnails without fetching remote images. This is not a full CommonMark/HTML/footnote renderer.
- Transient extension dialogs/widgets/statuses reset when disconnecting/reconnecting.

**⌘⇧N** creates a conversation; **⌘Return** sends; **⌘,** opens Settings. Type **@** for connected-project paths or **/** for available Pi commands, then click a completion or press **Tab**. Client and conversation menus expose additional actions.

Pi can execute tools with the permissions of the host account. PiDesk does not add a sandbox or automatically approve project trust. Disconnecting or quitting stops the GUI-owned processes; remote jobs are not a durable background service.

## Storage

Pi owns conversation history on each host, normally in `~/.pi/agent/sessions/`. PiDesk stores profiles, session references, and drafts in:

```
~/Library/Application Support/PiDesk/workspace.json
```

Closing conversations/removing clients does not delete Pi's session files. An unreadable workspace is not overwritten and does not auto-connect. Use **Settings → Workspace recovery** to import a trusted workspace or start fresh. The original file is backed up beside itself before replacement; recovery disconnects active conversations and never auto-connects imported profiles. For an isolated development workspace, launch with `PIDESK_WORKSPACE=/absolute/path/workspace.json`.

## Verification

```sh
scripts/test.sh
PIDESK_TEST_REAL_PI=1 scripts/test.sh --filter realPiHandshakeWithoutModelCalls
swift build
```

The test script handles the Swift Testing framework paths omitted by some Command Line Tools installations, without changing `xcode-select`. A macOS 13 deployment-target warning from the test framework is expected on newer toolchains; it does not affect the application build.

Tests cover framing/Unicode, RPC correlation/errors/timeouts/exits, streamed message assembly, tool deduplication, model/thinking controls, queue restoration, extension confirmations, session isolation, reconnect, compaction, quoting, and workspace persistence. The opt-in real-Pi test performs protocol queries only—no model/API call.

See [TODO.md](TODO.md) for remaining work and verification gaps.
