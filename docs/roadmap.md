# Roadmap

Beep Boop routes user messages, incoming events and scheduled follow-ups through
one main conversation: find related work, continue the existing task, and close
the loop quietly unless a result or decision is needed. This roadmap tracks what
ships today and what remains across stabilization, conversation UX, Rex
integration, host automation and history coverage.

Companion docs cover how shipped systems work: [architecture](architecture.md)
(ownership, execution and failover), [history](history.md) (import and hybrid
retrieval), [setup](setup.md) (services, trust, scheduled jobs and Dreams), and
[performance](performance.md) (benchmarks and evaluations).

## Shipped foundation

Built on [Pi Durable](https://github.com/earendil-works/pi/tree/main/packages/durable)
and [Pi telemetry](https://github.com/earendil-works/pi/tree/main/packages/telemetry)
1.6.0; upstream interfaces remain experimental and are verified at each pinned
upgrade.

- **Coordinator, durability and recovery.** One Rust supervisor and narrow
  TypeScript adapter over Pi SQLite own the main conversation, typed protocol
  schemas, steering/queueing/abort/compaction, attachment retention and bounded
  snapshot-to-live observation. Checksummed [backups and restore](setup.md#backups-and-restore)
  and opt-in epoch-fenced [failover](setup.md#failover) (Cloudflare Durable
  Object log + R2 blobs + operator-promoted standby) preserve single-writer
  ownership without duplicating external effects.
- **Terminal and iPhone clients.** The Ratatui TUI (`--no-tui` and `--json`
  supported) and the [iPhone app](../ios/README.md) (distributed via private
  TestFlight) share submission, steering, queueing, `/status`, `/machines`,
  `/worktrees` and read-only job/task inspection. iOS includes APNs main-chat
  and mid-job `notify_user` [alerts](notifications.md), crash-safe composer and
  outbox recovery, a Share extension, on-device Parakeet dictation behind
  `SpeechEngine`, Scrawl `/feedback` recordings, Siri/Shortcuts App Intents,
  Spotlight indexing and a CarPlay hands-free voice loop.
- **Tasks, scheduling and browser fallback.** Interactive tasks run in named Rex
  sessions with daemon-owned host effects that survive terminal exits and Rex
  restarts. Headless [scheduled jobs](setup.md#scheduled-jobs) and child agents
  run on Pi's durable sleeps without Rex terminals, reusing each job's task and
  conversation across timer and manual runs. Tasks coordinate directly via
  `message_task`, track host-verified file outcomes via `/goal`, and clean up
  merged worktrees on a guarded five-minute sweep. Main defers rare tools behind
  `tool_search`, while triage, worker and child-agent roles batch calls in
  `codemode` scripts (~30% lower suite token use on the
  [tool discovery eval](performance.md#tool-discovery)). Supported OpenAI models
  have hosted web search, and signed-in Chrome automation via Playwright +
  1Password CLI serves as the browser fallback.
- **Sources, retrieval and reviewed learning.** Gmail and Calendar (`gws`),
  GitHub (`gh`), Slack and macOS `messages` pollers feed backlog-safe triage
  lanes verified by deterministic and live [loop-closing evaluations](architecture.md#validation).
  Incremental Codex and `chatgpt` imports feed a rebuildable SQLite FTS +
  binary-shortlist/exact-reranked vector index (2.9 s median reader latency at
  1.35M chunks) with `read_file` native image support and Photon preparation.
  Nightly log review and confined [Dreams](setup.md#dreams) runs propose at most
  one tested guidance diff per run, applied only when a human approves its exact
  `outcome_sha256`.

## Stabilization and acceptance

Finish physical-hardware and real-archive proofs for shipped code, fix observed
iPhone transcript defects, and close remaining runtime and evaluation gaps.

### Device and live-data acceptance

- [ ] **Siri, Shortcuts and Spotlight on a locked iPhone.** **Open
  Coordinator**, **Open Job**, **Retry Interrupted Run**, confirmed single-line
  **Send Message** (`siri` outbox origin; refuses `/` and `?` commands),
  onscreen entity reporting, `ToolIntent` / local-device authentication policies
  and the complete-protection `coordinators-and-jobs` Spotlight index ship with
  automated checks ([details](../ios/README.md#siri-and-shortcuts)). Verify Siri
  by voice, **Send Message** and Spotlight lock-screen protection on a physical
  locked iPhone.
- [ ] **CarPlay in-vehicle verification.** The CarPlay scene, voice loop
  (`carplay` outbox origin, readback confirmation, concise spoken reply, lock
  and microphone prechecks) and entitlement build gates ship
  ([details](../ios/README.md#carplay)). Once the
  `com.apple.developer.carplay-voice-based-conversation` entitlement is
  provisioned, verify templates, car microphone/speakers, end-of-speech timing
  in motion, audio interruptions, rapid state throttling and locked-phone launch
  in a car or CarPlay Simulator.
- [ ] **Chrome lifecycle reboot on a deployment host.** Disposable Tart macOS
  guests (installed Chrome, Web Store extension, saved-password autofill, Rex
  and LaunchAgent) pass `relaunch`, `kill_helper`, `kill_service` and
  `os_reboot`, and local Chrome for Testing passes `relaunch`, `kill_helper` and
  `kill_service` ([Chrome lifecycle acceptance](chrome-acceptance.md)). Run the
  `os_reboot` leg on an existing deployment host using its default Chrome data
  root and macOS login reopen.
- [ ] **Real ChatGPT export verification.** `beep-boop import chatgpt` validates
  and imports invented single- and multi-part exports end to end across
  interruption, reruns and edited branches ([ChatGPT exports](history.md#chatgpt-exports)).
  Run `--check` and full import against a real account export and record its
  counts, digests, coverage gaps and unsupported content.

### iPhone transcript and reconnect polish

Real-device UI audit findings from macOS iPhone Mirroring on iPhone 16 Pro
(`iPhone17,1`, iOS `27.3`, Beep Boop `0.1` build `416`; deduplicated against
`#71` and `#95`). Examples use invented text; private captures are retained
outside this repository by evidence ID.

- [ ] **`UI-001` (High, observed, `EVID-20261120-A1`) — Reconnect drops
  reasoning summaries and shifts open tool cards.** After background disconnect
  and foreground reconnect, an expanded activity group (`5 tool calls · 4
  summaries` with an open `Shell` card) drops all summaries while `Connecting`
  and settles permanently with missing summaries (`5 tool calls · 2 summaries`),
  shifting the open `Shell` card upward by ~1 row (~30–35 pt). *Acceptance:*
  Across background disconnect and foreground reconnect, an expanded group
  retains all N summaries in its header and body with zero vertical jump of an
  open child tool card.
- [ ] **`UI-002` (Medium-High, observed, `EVID-20261120-B1`) — Expanding the
  live activity group stalls follow-tail and clips rows.** Expanding the active
  activity disclosure at the live tail pushes `Working...` and newly streamed
  tool rows half-clipped behind the composer without advancing follow-tail, and
  delays showing `↓ Latest` until several more items append. *Acceptance:*
  Expanding the active group at the live tail either keeps new tool rows and
  `Working...` fully visible above the composer or immediately enters manual
  reading with `↓ Latest` shown and no mid-line clipping.
- [ ] **`UI-003` (Low-Medium, observed, `EVID-20261120-B2`) — Floating
  `↓ Latest` pill obscures transcript content.** When scrolled above the tail,
  the opaque `↓ Latest` pill covers bottom-right disclosure chevrons on
  collapsed activity rows and the right side of the bottom two lines inside an
  expanded `Shell` card. *Acceptance:* `↓ Latest` remains legible above the tail
  without overlapping `Shell` output text or row disclosure controls.
- [ ] **`UI-004` (Low-Medium, observed, `EVID-20261120-O1`) — Consecutive
  reasoning summaries concatenate with literal `****`.** Back-to-back bolded
  reasoning summaries in one activity group render inline on a single line with
  raw `****` delimiters (e.g., `Inspecting report status****Reviewing message
  text`). *Acceptance:* Consecutive bolded summaries render as distinct lines or
  blocks with no visible `*` delimiters.
- [ ] **`UI-005` (Low, observed, `EVID-20261120-A2`) — Connection banners
  collide with the top transcript line.** When scrolled mid-conversation,
  `Disconnected` / `Try again` and foreground `Connecting` (plus its spinner)
  sit flush against or overlap the top visible message line before shifting the
  feed on clear. *Acceptance:* Connection status banners reserve dedicated
  vertical space above the transcript with no text or spinner collision.
- [ ] **`UI-006` and `UI-007` (Blocked device trials, `EVID-20261120-B3`,
  `EVID-20261120-BLOCK`) — Cold relaunch, scope switching and live-stream detail
  anchoring.** Complete the physical-iPhone checks interrupted when mirroring
  ended (`iPhone in Use`): (1) 2–3 trials each of switching coordinator scope
  (`Work` ↔ `All coordinators` ↔ second coordinator), navigating into
  `Connection → Jobs and work` and back, and cold app relaunch (`UI-006`); and
  (2) reading an expanded `Shell` card during rapid live-tail streaming,
  neighboring collapse/expand and keyboard toggle without unexpected viewport
  jumps (`UI-007`; off-tail control passed 1/1).

### Runtime, CLI and evaluation hardening

Follow-ups from the live loop-closing eval
([#72](https://github.com/sammyjoyce/agent/issues/72)) and upstream Pi reuse
qualification ([#52](https://github.com/sammyjoyce/agent/issues/52)).

- [ ] **Silence outcome triage on user-handled threads
  ([#72](https://github.com/sammyjoyce/agent/issues/72)).** On the 7-case live
  loop-closing eval (`gpt-6.1-sol`, 6/7 passing), when a thread was already
  handled by the user, the resumed worker resolved the task without booking and
  outcome triage still posted a needless main-chat completion notice. Keep
  outcome triage quiet when the user already handled the exchange.
- [ ] **Model-aware image attachment limits.** Prepare attached images with the
  active conversation model's image limits rather than fixed defaults (`#52`).
- [ ] **Cross-host and cancellation image-read coverage.** Add end-to-end
  `read_file` image tests for triage and child-agent routes across two machines,
  and for cancelling a slow transfer (`#52`).
- [ ] **Shrink the worker `codemode` prompt budget.** Reduce inline schema weight
  in the worker role's `codemode` prompt section using tool namespaces or a
  smaller inline budget (`#52`).
- [ ] **Semantic `child-agent` oracle and full-suite requalification.** Replace
  the wording-based `child-agent` check in the tool discovery eval (which still
  accepts post-sentence denials or phrases like "ruled out", "excluded",
  "instead of" and "discarded theory") with a meaning check, then rerun the full
  nine-scenario confirmation at `low` and default reasoning while retaining
  every answer (`#52`).
- [ ] **Bridge, CLI and CI test hygiene (`#52`).**
  - Add a bridge-level regression test proving an oversized task-graph request
    fails cleanly without breaking the bridge.
  - Emit structured JSON error objects when a `--json` CLI command fails.
  - Make event waits in `runtime/test/native-main.test.ts` cancellation-aware so
    missing events fail at timeout instead of hanging.
  - Restore Linux real-browser CI coverage by supplying `libglib-2.0` for pinned
    Chromium on NixOS hosts and forwarding the browser fixture's `GITHUB_ENV`.

## Conversation and visibility

Make background execution, nightly proposals, message-targeted replies and
branching conversations legible directly from the main chat.

### Active work in the main chat

- [ ] **Read-only live work strip, sheet and TUI panel.** Show tasks and
  scheduled jobs that are running or waiting now without leaving the main
  conversation (replacing ad-hoc `beep-boop tasks graph` snapshots outside chat,
  while **Jobs and work** continues to list next runs and saved conversations).

  ```text
  2 running · 2 waiting         1 needs you  v     the strip, under the title

  Active work                               x     the sheet, over the chat
  Running
    Fix login redirect                    12m
    desktop · exec
    Update dependencies                    3m
    laptop · exec
  Waiting
    Board review                        1h 8m
    desktop · needs your reply
    Fix CI on main                        26m
    server · on GitHub checks
  ```

  - **iPhone strip and sheet.** One line under the chat title shows counts of
    running work, waiting work and work waiting on the owner; when all three are
    zero, the strip is hidden. Tapping opens a read-only sheet (**Running** and
    **Waiting**; swipe down to return). Work waiting on the owner sorts first in
    **Waiting** with the only colored mark, and `omitted` task counts are shown
    as in `tasks graph`. Each two-line row shows status mark, title, host (or
    **Job**), current tool or wait reason, and elapsed duration. No control
    starts, stops, retries or answers work; unstarted jobs stay on **Jobs and
    work**.
  - **Terminal UI.** Full-screen panel with the same two groups and live tool
    calls and child agents indented under running rows (panel prototyped), plus
    live counts in the footer beside model and path (not yet prototyped).
  - **Layouts set aside.** Separate page (leaves main chat), grouping by host
    (scatters owner-blocked work), past-hour timeline (`ScheduledJobStatus`
    keeps `last_run` only), and inline expanding panel (drops host/tool at one
    line or covers the chat at two).
  - **Prerequisites.**
    1. Add `NativeRequest` task-graph reads, generated Swift `TaskRecord` /
       `TaskGraphSnapshot` types, and a `NativeEvent::Ready` capability flag
       beside `work_inspection` so older coordinators keep the strip hidden.
    2. Add a live task-graph watch ([#52](https://github.com/sammyjoyce/agent/issues/52))
       so clients subscribe instead of polling single `ReadTaskGraph` snapshots.
    3. Add a typed waiting-on-owner state (`TaskState::Waiting` currently stores
       model-written free-text `actor`).
    4. Record task `started_at` (`TaskRecord` currently has `updated_at` only;
       `JobExecution` already has `started_at`).
    5. Carry bounded tool-argument context in the task graph if rows should show
       more than bare tool names such as `exec`.
  - **Open owner decisions.** Strip placement (under chat title vs. above
    composer); whether open tasks with no live activity appear or stay omitted;
    whether tapping a row opens read-only conversation inspection or does
    nothing.
  - **Acceptance.** On a real iPhone against a coordinator with running and
    waiting work, strip counts match sheet rows and update live without refresh;
    the strip hides when idle or when connected to a coordinator without the
    capability; no sheet control mutates task or job state.

### Dreams review and approval on iPhone

- [ ] **Native iOS inspection and approval for [Dreams](setup.md#dreams).**
  Browse nightly Dreams runs, inspect sealed proposals and approve them from the
  iPhone app (today `dreams list`, `show` and `apply` exist only in the CLI
  reading the coordinator's local state directory).
  - **Behavior.** List runs newest-first with window, coverage, outcome and
    proposal status (`pending`, `applied`, `stale`, `target_dirty`,
    `target_locked`, `patch_changed`, `policy_changed`). Opening a run shows
    coverage gaps, before/after check results, quoted model rationale or
    abstention note, bounded cited evidence, and the patch with control and
    Unicode format characters escaped so rendered bytes match what `apply`
    commits.
  - **Safety and protocol prerequisites.** Approving a `pending` proposal
    requires explicit confirmation and sends that run's exact sealed
    `outcome_sha256`, running the same coordinator-side hash, policy, base,
    clean-worktree and single-apply checks as `beep-boop dreams apply`. Add
    `NativeRequest` Dreams operations, a `NativeEvent::Ready` capability flag
    (hiding Dreams when `[dreams]` is unconfigured or unsupported), and
    generated Swift types. Keep Dreams reads and apply strictly on the
    authenticated coordinator boundary outside Pi's runtime and tool surface so
    no model or conversation tool can approve or apply a proposal.
  - **Open owner decisions.** Whether Dreams lives only under coordinator
    controls beside **Jobs and work** or also surfaces a notice when a nightly
    run has a pending proposal, and whether to ship read-only inspection ahead
    of remote apply.

### Targeted replies, sidechats and transcript fidelity

- [ ] **Reply to a specific message on iPhone.** Add **Reply** to the iPhone
  message menu alongside **Copy message**, **Select text** and **Share text**,
  mirroring Apple Messages. Selecting **Reply** pins the target message above
  the draft composer until sent or cancelled, attaches that message's identity
  to the submitted input, renders the quoted message with the reply in the
  transcript, and tells the model which earlier message is being answered.
- [ ] **Sidechats** (inspired by Meta's Muse). Open a side conversation anchored
  to a message to explore a follow-up without interrupting or expanding the main
  chat. Return to the anchor message when done and bring an answer back into the
  main conversation only on explicit choice (revisiting Pi Durable conversation
  forks if needed; see [architecture](architecture.md#tasks-and-execution)).
- [ ] **First-class transcript items for nested `codemode` calls.** Render
  nested `exec`, `write_file` and `edit_file` calls recorded in a `codemode`
  script's `details.calls` as standalone **Command** and **File changes** items
  in triage, worker and child-agent transcripts instead of plain lines inside
  the code mode block ([#52](https://github.com/sammyjoyce/agent/issues/52)).

## Rex integration and exploration

Reviewed against Superlogical's Oct 21–Nov 21, 2026 updates and a Nov 22, 2026
server/client and binary audit through Rex `0.1.0-preview.22` /
`0.1.0-snapshot.2494` (control API revisions 18–19). Several shipped surfaces
appear only in server `/api/help`, `/llms.txt` or compiled binaries rather than
`superlogical.com/rex/docs`, so adoption must gate on `api_revision` and runtime
capability discovery. Keep `rex_instance_id` restart fencing in `src/rex.rs`:
`block.close` still has no conditional precondition and native agent-session
restore is not shipped yet.

### Terminal, host and CLI integration

- [ ] **Program Status Protocol (`OSC 7501`) in the TUI.** Emit `OSC 7501`
  alongside `WindowTitle` in `src/tui/inline.rs` using `app=beep-boop` and the
  same control-character/bidi sanitization as `terminal_title`. Map active turns
  and goals to `working` (`msg`, bounded `progress`), authentication failures
  and typed owner-waiting states to `blocked` (`auth`, `question`,
  `permission`), completions to `done`, failures to `error`, idle/cancelled runs
  to `idle`, and clean detach to `clear`, with hierarchical child `id=...`
  records for child agents and delegates across Rex's Activity Mode, tab
  indicators, Dock badge, `Go to Anything` and future mobile notifications.
- [ ] **Full Disk Access preflight (`server.apple.privacy_status`).** Query
  `server.apple.privacy_status` over the local Unix socket (no TCC prompt) in
  `beep-boop rex install` (`src/rex/install.rs`) and Messages source diagnostics
  to verify `full_disk_access` is `granted` and report `responsible_path` when
  missing, gating on `server.version` and `method_not_found` for non-macOS hosts
  and older servers.
- [ ] **Remote file drag-and-drop and clipboard image paste.** Verify Rex client
  uploads (`com.superlogical.terminal.upload_begin`) against `dropped_files` in
  `src/tui/attachments.rs`, covering shell quoting, batch spacing, trailing
  newlines and uploaded temp-file lifetime between drop and Send.
- [ ] **`OSC 8` links and Quick Look artifact paths.** Emit `OSC 8` hyperlinks
  for web-search sources and clean absolute paths for local artifacts (browser
  screenshots, Dreams diffs, edited files) in completed TUI scrollback rows so
  Rex Quick Look (`⇧⌘+Click`, `⌘Y`, and remote
  `com.superlogical.terminal.download_begin`) previews them natively.
- [ ] **SSH worker hosts (`ssh://`).** Support Rex SSH endpoints (`rex hosts`
  and `rex server install ssh://<address>`) alongside Tailscale in node
  discovery (`src/discovery.rs`) and worker setup docs so Linux VMs without
  Tailscale can join as Rex-backed worker hosts.
- [ ] **Bounded feedback terminal capture.** Tighten `capture_terminal` in
  `src/rex.rs` using `--trim` and/or `com.superlogical.terminal.format`
  (`max_bytes` + `blob_read`) so large styled captures degrade cleanly.
- [ ] **Optional Rex Lua action module.** Provide a Lua module using
  `rex.ui.pick` / `rex.ui.input` (callable via `rex do`) and `client.perform`
  (`session.select`) to jump to active or waiting tasks across devices or send a
  quick prompt to main chat. Keep it separate from core execution and durable
  approvals since `client.perform` requires Remote Control and `rex.ui` needs an
  attached Rex app.
- [ ] **Maturing secondary Rex surfaces.** Evaluate clickable localhost URLs /
  `rex forward open` for remote dev servers; floating/minimized panes
  (`session.new_layer`, `session.set_layer_state`) as an optional host for
  Sidechats or Active work while keeping task agents in named tabs; size-capped
  opt-in Kitty graphics thumbnails in TUI scrollback; headless macOS and Windows
  Rex servers; and new Superlogical terminal protocol proposals before investing
  in a standalone macOS desktop GUI.

### Protocol, Block SDK and iOS client exploration

- [ ] **Direct `rex.control.v1` WebSocket client (`GET /api/control`).** Explore
  speaking Rex's control protocol directly from iOS (`ios/Sources/AgentCore`,
  `ios/Sources/AgentUI`) and Rust (`src/rex.rs`) instead of shelling out to the
  CLI, covering `hello`/`welcome` negotiation (`api_revision`,
  `api_min_revision`, `reconnect_token`, `max_message_bytes`), single-roundtrip
  `session.bootstrap` with upfront data tickets (rev 8), `event_dropped` (rev
  18) resync, block ownership (`block_owner_changed`,
  `session.own_block`/`disown_block`), forward-compatible `carriers` (such as
  QUIC ALPN), and undocumented session/client events (`session_moved`,
  `client_call_requested`, `client_perform_requested`, `client_performed`,
  `client_prompt_requested`, `client_prompt_ended`,
  `client_script_events_dropped`).
- [ ] **Direct `GET /api/data` framing and `rex.data.bytes.v1`.** Explore Rex's
  binary `/api/data` WebSocket handshake (`HELLO` 17 B, `RESUME` 25 B, `WELCOME`
  32 B with 60 s reconnect token and 64-bit channel nonce, `REJECT` 2 B reasons
  `0x01`–`0x07`, documented on server `/llms.txt`) and `rex.data.bytes.v1` in
  the iOS client to stream remote file downloads (`download_begin` with
  `if_none_match`/`version`, `download:<uuid>`), uploads (`upload_begin`,
  `upload:<uuid>`) and tunneled TCP connections (`conn:<name>`) directly between
  iOS and execution hosts.
- [ ] **Live iOS terminal streaming (`rex.data.terminal.v1`) vs. snapshot
  reads.** Compare full `rex.data.terminal.v1` streaming (Ghostty snapshot
  header plus APC `ESC _ rex1;<nonce>;<json> ESC \` frames for `resize`, `theme`
  and `child_exited`, with byte-exact `RESUME` recovery) against on-demand
  `com.superlogical.terminal.format` (`max_bytes` + `blob_read`) reads so iOS
  can inspect live Rex panes without requiring an embedded Ghostty renderer
  upfront.
- [ ] **Out-of-process Rex Block SDK (`--block-dir` / `--block-plugin-reload`).**
  Explore an experimental Beep Boop block creator using Rex's server plugin
  machinery (`rex-block-*` discovery, `REX_BLOCKSERVER_INFO_FD` handshake, the
  7-RPC `blockserver` lifecycle—`creator.list`, `block.create`, `block.method`,
  `block.event`, `block.snapshot`/`block.restore` with shared-FS `dir`, and
  `block.close`—plus `block_creator.list`'s `features` field). Because official
  macOS/iOS Rex apps currently hardcode `RexSync.BlockProvider` to
  `com.superlogical.terminal` and `com.superlogical.onboarding`, custom blocks
  would render first in Beep Boop's iOS client while tracking upstream Rex's
  public Block SDK; treat `Rex.app` `rex.server.*` UserDefaults as local
  prototyping hooks only.
- [ ] **Built-in non-terminal blocks (`tunnel` and `onboarding`).** Explore
  `com.superlogical.tunnel` (rev 14; detached `dial`/`listen` flavors, `info`,
  `connection_requested` event, `rex.data.bytes.v1` transport) for on-demand TCP
  tunnels from iOS and workers without shelling out to `rex forward`, and study
  `com.superlogical.onboarding` (rev 7; `state`/`set_step`, generation-stamped
  `step_changed`, zero data stream) as the reference pattern for stateful
  non-terminal blocks.
- [ ] **Extended `com.superlogical.terminal` methods and events.** Explore
  server-documented terminal APIs across the coordinator, TUI and iOS client:
  `ports` (rev 15) and `ports_changed` (rev 16) to surface live worker
  dev-server ports in Active work / iOS alongside `tunnel`; `list_dir` for
  shell-free remote file browsing from iOS; `blob_read` (rev 6),
  `clipboard_read` and `selection_copied` for chunked output and selection
  reads; and `modes` (rev 3), `input_mode`, `process`, `program_status`, `size`,
  `size_changed`, `url_clicked`, `clear`, `resize` and `set_theme` for richer
  pane inspection (alternate screen, no-echo prompts, process ancestry and URL
  handoff).
- [ ] **Focus history (`focus_history.reverse`) and macOS `Rex.app` surfaces.**
  Explore control API rev 19 `focus_history.reverse` for jumping across recent
  task panes, tabs and sessions from workflows and iOS, plus `Rex.app`'s
  `Rex.sdef` AppleScript dictionary (`sessions`, `hosts`, `actions`, `current
  session`, `run command`, `new session`, `show`, `perform`) and six App Intents
  (`GetRexSessionsIntent`, `NewRexSessionIntent`, `OpenFoldersInRexIntent`,
  `OpenRexSessionIntent`, `RunRexActionIntent`, `RunRexCommandIntent`) for macOS
  Shortcuts and local tooling. Keep `rex __internal` subcommands (`dial-stdio`,
  `autostart-status`, `tcc-preflight`, `ssh-tunnel`, `askpass`, `session-start`,
  `skill`) off direct dependencies and track upstream `rex block new` / `rex
  block stream` implementation.

## Host integrations and automation

Extend local machine visibility and host actions while preserving the
[integration order](architecture.md#integrations-and-scheduling): supported APIs
and configured CLIs first, Chrome tools second, and desktop computer use last.

### macOS menu bar status app

- [ ] **Local service status in the macOS menu bar.** Ship a lightweight macOS
  menu bar app showing Beep Boop's status on that Mac, including whether the
  local service is running and its installed versus running versions.

### Apple Notes, Reminders, Mail and Messages (`macctl`)

- [ ] **Typed Apple app access through `macctl`
  ([design #31](https://github.com/sammyjoyce/agent/issues/31)).** Move the
  signed Swift daemon into `macos/macctl/` behind `HostCommand::Apple`. Requests
  route exclusively to the configured Mac that owns the data, and that Mac's
  configured tiers determine which `apple_read`, `apple_change` and `apple_send`
  methods exist. Every write commits a durable operation record before dispatch;
  an unknown outcome blocks further writes to that app until settled.
  - **Prerequisites and open owner decisions.** Implement the four guarantees
    `macctl` currently lacks ([#31](https://github.com/sammyjoyce/agent/issues/31)),
    and decide per-send approval rules, triage write permissions and the
    design's remaining policy questions.

### Desktop computer use fallback

- [ ] **Accessibility-tree desktop control.** Add host desktop app automation as
  the final fallback for apps no API, CLI or Chrome tool reaches, using or
  building on [`agent-desktop`](https://github.com/vercel-labs/agent-desktop)
  (Apache-2.0 CLI, MCP server and C library for macOS, Windows and Linux).
  `agent-desktop` reads an app's accessibility tree as JSON with element refs,
  acts on a ref, and re-reads the tree to verify the result—requiring no
  screenshots, pixel matching or embedded model so the loop remains in Pi. Ref
  actions leave pointer and focus untouched unless `--headed` is set, and macOS
  requires the Accessibility grant.
  - **Open decisions and constraints.** Decide whether to invoke `agent-desktop`
    directly or build on its design, and bound private desktop content exposure
    across accessibility snapshots, screenshots and clipboard reads.

## History, sources and multi-host

Expand searchable archive coverage, optional domain feeds and cross-host task
portability.

- [ ] **[Grok Bot](https://docs.x.ai/grok-bot/overview) conversation import.**
  Support resumable, idempotent ingestion with attachment coverage matching
  Codex and ChatGPT imports. Grok Bot currently documents per-call transcripts
  and per-message downloads rather than an account-wide export, so the import
  source remains open.
- [ ] **Optional domain event sources.** Add opt-in API or CLI adapters where
  workflows outgrow ordinary mail intake—such as Home Assistant repairs and
  state changes via its API, or MyChart and Ramp activity via existing CLIs—with
  all credentials kept in the configured private credential provider
  ([architecture](architecture.md#integrations-and-scheduling)).
- [ ] **Cross-host worker transfer.** Offline workers currently retain their
  bound tasks until the host reconnects, and coordinator failover leaves host
  bindings unchanged. Support transferring an offline host's task to another
  online machine while preserving conversation and resource lineage.
