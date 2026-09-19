# Remaining work / handoff

## Current checkpoint

The mockup is wired to real local/SSH Pi RPC processes. The hardening/polish implementation below is now in place and the application compiles. Per request, this pass did not run tests, launch the GUI, capture screenshots, send live model prompts, or connect to SSH hosts. Earlier test results predate these changes; runtime validation remains pending.

Main files:
- `PiDeskApp.swift`, `MessageViews.swift`, `Sheets.swift`: existing visual design with functional controls.
- `RPCConnection.swift`: process lifecycle, strict LF JSONL, request correlation, timeouts, diagnostics.
- `SessionController.swift`: per-conversation state, streaming reducer, RPC commands, extension UI.
- `DeskStore.swift`, `Models.swift`: profiles, persistence, selection, session discovery.
- `Resources/list-sessions.js`: cancellable, cached read-only local/remote metadata discovery.
- `Resources/session-process.js`: host-side writer locks and Pi process supervision.
- `PiResources.swift`, `scripts/build-app.sh`: packaged app resources and build/install.
- `Tests/PiDeskTests/`: deterministic fake RPC peer and automated tests.

## Highest priority: finish verification

- [ ] Run the actual GUI and compare visually with the original mockup. Layout and styles were retained in code, but no screenshot/UI automation pass has been done.
- [ ] Send a real prompt with an authenticated provider. Verify live text, thinking, tools, Stop/Escape, steering, errors, and model changes. The real-Pi smoke test only exercised protocol queries.
- [ ] Test a real SSH host: authentication failure, untrusted host key, custom port, SSH alias, remote PATH/version managers, dropped network, reconnect, quit, and remote process cleanup.
- [ ] Verify saved-session discovery on both local and remote hosts. Add automated fixtures for malformed/large files, permission errors, custom Pi session directories, and concurrent file writes.
- [ ] Manually test app relaunch, session switching while multiple conversations stream, client editing/removal during work, and application termination with active tools.
- [ ] Verify extension startup dialogs and timeout behavior with actual extensions, not only the fake RPC peer.
- [ ] Validate hardening changes: lock contention through aliases, crash/stale-lock recovery, discovery cancellation/cache invalidation, delivery-unknown recovery, workspace backup/import failures, and expanding long transcripts.
- [ ] Build/install the packaged app and verify launching from Finder's environment.

## Hardening/polish implementation (validation pending)

- [x] Host-side writer locks survive closing/removing controllers until Pi exits. Real paths on the host unify symlinks and equivalent SSH aliases. Contention fails with recovery guidance; locks are never stolen automatically. Terminal Pi clients do not honor these advisory locks.
- [x] Session discovery has cancellation, progress/skipped counts, bounded parallel reads, snapshot-size reads for concurrently growing files, and an in-memory metadata cache keyed by file identity/size/timestamps. The cancellable timeout is now five minutes. Edit client accepts a custom session directory for discovery and new conversations.
- [x] Persist delivery-unknown text separately from drafts after prompt timeouts/connection loss. Pause sending until the user explicitly discards it or restores it for manual resend. Failed state queries after acceptance no longer restore accepted prompts.
- [x] Follow-bottom responds to transcript geometry changes, including thinking/tools/images, and provides a jump-to-latest button. Scrolling behavior still needs the manual validation listed above.
- [x] Expand common Markdown support for tables, nested/ordered/task lists, headings, and quotes. Render supported embedded images with bounded thumbnails. Markdown export includes thinking/tool arguments/results/images; full-history JSON export includes raw entries from all branches. Full CommonMark/HTML/footnotes remain outside the lightweight renderer.
- [x] Clear transient extension dialogs, widgets, status text, and command caches across reconnect; old dialog timers cannot affect a new connection.
- [x] Settings provides trusted-workspace import and start-fresh recovery, with validation, backup of the original, disconnection of active conversations, and no automatic connection after import.
- [x] Add `scripts/build-app.sh` with conventional bundled SwiftPM resources, ad-hoc signing, and optional installation to `~/Applications`. Packaging/Finder verification remains pending above.

## Not implemented / scope boundaries

- Attaching to an already-running Pi TUI or durable remote/background sessions.
- Session tree navigation, branching/fork/clone UI, general file attachments, provider login inside the GUI. Clipboard image attachments are supported.
- Automatic reconnect/replay: reconnect is explicit to avoid replaying prompts or silently restarting tools.
- A replacement for all terminal slash commands: common TUI-only commands are blocked with guidance; extension/skill/template commands pass through to Pi.

Keep the existing visual design; use the existing menus/sheets for further functionality rather than redesigning the main screen.
