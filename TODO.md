# Remaining work / handoff

## Current checkpoint

The mockup is now wired to real local/SSH Pi RPC processes. The application builds, the 16 non-optional automated tests pass, and the additional real-local-Pi handshake test passes. No paid model calls or live SSH connections were made during validation.

Main files:
- `PiDeskApp.swift`, `MessageViews.swift`, `Sheets.swift`: existing visual design with functional controls.
- `RPCConnection.swift`: process lifecycle, strict LF JSONL, request correlation, timeouts, diagnostics.
- `SessionController.swift`: per-conversation state, streaming reducer, RPC commands, extension UI.
- `DeskStore.swift`, `Models.swift`: profiles, persistence, selection, session discovery.
- `Resources/list-sessions.js`: read-only local/remote session metadata discovery.
- `Tests/PiDeskTests/`: deterministic fake RPC peer and automated tests.

## Highest priority: finish verification

- [ ] Run the actual GUI and compare visually with the original mockup. Layout and styles were retained in code, but no screenshot/UI automation pass has been done.
- [ ] Send a real prompt with an authenticated provider. Verify live text, thinking, tools, Stop/Escape, steering, errors, and model changes. The real-Pi smoke test only exercised protocol queries.
- [ ] Test a real SSH host: authentication failure, untrusted host key, custom port, SSH alias, remote PATH/version managers, dropped network, reconnect, quit, and remote process cleanup.
- [ ] Verify saved-session discovery on both local and remote hosts. Add automated fixtures for malformed/large files, permission errors, custom Pi session directories, and concurrent file writes.
- [ ] Manually test app relaunch, session switching while multiple conversations stream, client editing/removal during work, and application termination with active tools.
- [ ] Verify extension startup dialogs and timeout behavior with actual extensions, not only the fake RPC peer.

## Known hardening/polish tasks

- [ ] Enforce one writer across closing/reopening sessions and equivalent host aliases. Reconnect within a controller waits for its old process to exit, but closing/removing and immediately reopening the same file can create a new controller before the old process finishes. External terminal clients are not locked out; the session browser warns about concurrent use.
- [ ] Session discovery scans all session files on the host and has a 25-second timeout. Add cancellation/progress and optimize large inventories. Custom per-invocation `--session-dir` locations are not discoverable unless configured in the host environment.
- [ ] A timed-out prompt may already have been accepted. The error explains this, but the draft is restored; add an explicit delivery-unknown state to reduce accidental duplicate resends.
- [ ] Test/fine-tune follow-bottom scrolling for long responses and expanding thinking/tool sections. Only message count and last-body updates currently trigger scrolling.
- [ ] Add full Markdown support if needed (tables/nested lists are basic); transcript export currently exports displayed message bodies, not complete Pi history, thinking, or tool arguments. Image blocks are represented as `[Image]`, not rendered.
- [ ] Explicitly refresh/reset transient extension widgets and statuses after reconnect. Some extension UI features are intentionally unsupported by Pi's RPC mode.
- [ ] Provide UI recovery/import for an unreadable workspace file; currently persistence is disabled to protect the original file and an error shows its path.
- [ ] Add a packaged `.app` build/install script with bundled SwiftPM resources, then test launching from Finder's environment. Current documented launch is `swift run PiDesk`.

## Not implemented / scope boundaries

- Attaching to an already-running Pi TUI or durable remote/background sessions.
- Session tree navigation, branching/fork/clone UI, file/image attachments, provider login inside the GUI.
- Automatic reconnect/replay: reconnect is explicit to avoid replaying prompts or silently restarting tools.
- A replacement for all terminal slash commands: common TUI-only commands are blocked with guidance; extension/skill/template commands pass through to Pi.

Keep the existing visual design; use the existing menus/sheets for further functionality rather than redesigning the main screen.
